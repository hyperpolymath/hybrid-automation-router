# HAR Self-Hosted Deployment Guide

**Purpose:** Production-ready deployment using Podman + Salt Stack

This guide covers deploying HAR in a self-hosted environment without reliance on cloud providers. Uses Podman for containerization (rootless, daemonless) and Salt Stack for configuration management.

## Architecture Overview

```
┌────────────────────────────────────────────────────────────┐
│                  Load Balancer (HAProxy)                    │
│                  https://har.company.com                    │
└─────────────────────────┬──────────────────────────────────┘
                          │
         ┌────────────────┼────────────────┐
         │                │                │
┌────────▼──────┐  ┌──────▼──────┐  ┌─────▼────────┐
│  HAR Node 1   │  │ HAR Node 2  │  │ HAR Node 3   │
│  (Podman)     │  │ (Podman)    │  │ (Podman)     │
│  10.0.1.10    │  │ 10.0.1.11   │  │ 10.0.1.12    │
└───────┬───────┘  └──────┬──────┘  └──────┬───────┘
        │                 │                 │
        └─────────────────┼─────────────────┘
                          │
                ┌─────────▼──────────┐
                │   IPFS Cluster     │
                │   (3 nodes)        │
                │   Content Storage  │
                └────────────────────┘
```

## Prerequisites

**Hardware Requirements:**

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| CPU | 2 cores | 4 cores |
| RAM | 4 GB | 8 GB |
| Storage | 20 GB | 100 GB SSD |
| Network | 100 Mbps | 1 Gbps |

**Software Requirements:**
- OS: Rocky Linux 9 / Ubuntu 22.04 LTS
- Podman 4.0+
- Salt 3006+
- IPFS go-ipfs 0.20+

## Installation

### 1. Base System Setup

**Install Podman (Rocky Linux):**

```bash
# Enable EPEL
dnf install -y epel-release

# Install Podman
dnf install -y podman podman-compose

# Enable user namespaces (rootless)
echo "user.max_user_namespaces=15000" > /etc/sysctl.d/userns.conf
sysctl -p /etc/sysctl.d/userns.conf

# Configure subuid/subgid
echo "haruser:100000:65536" >> /etc/subuid
echo "haruser:100000:65536" >> /etc/subgid
```

**Install Podman (Ubuntu):**

```bash
# Install Podman
apt-get update
apt-get install -y podman podman-compose

# Configure cgroup v2
systemctl enable --now systemd-oomd
```

**Install IPFS:**

```bash
# Download and install
wget https://dist.ipfs.io/go-ipfs/v0.20.0/go-ipfs_v0.20.0_linux-amd64.tar.gz
tar xvf go-ipfs_v0.20.0_linux-amd64.tar.gz
cd go-ipfs
./install.sh

# Initialize IPFS
ipfs init --profile server

# Configure IPFS
ipfs config Addresses.API /ip4/0.0.0.0/tcp/5001
ipfs config Addresses.Gateway /ip4/0.0.0.0/tcp/8080

# Start IPFS daemon
systemctl enable --now ipfs
```

### 2. Salt Stack Configuration

**Salt Master Setup:**

```bash
# Install Salt
dnf install -y salt-master salt-minion

# Configure Salt master
cat > /etc/salt/master.d/har.conf <<EOF
file_roots:
  base:
    - /srv/salt/base
    - /srv/salt/har

pillar_roots:
  base:
    - /srv/pillar

interface: 0.0.0.0
auto_accept: False
EOF

# Start Salt master
systemctl enable --now salt-master
```

**Salt States for HAR:**

```yaml
# /srv/salt/har/har.sls
har_user:
  user.present:
    - name: haruser
    - shell: /bin/bash
    - home: /opt/har

har_directories:
  file.directory:
    - names:
      - /opt/har
      - /opt/har/config
      - /opt/har/data
      - /opt/har/logs
    - user: haruser
    - group: haruser
    - mode: 755

har_config:
  file.managed:
    - name: /opt/har/config/runtime.exs
    - source: salt://har/files/runtime.exs.jinja
    - template: jinja
    - user: haruser
    - group: haruser
    - mode: 644

har_systemd_service:
  file.managed:
    - name: /etc/systemd/system/har.service
    - source: salt://har/files/har.service
    - user: root
    - group: root
    - mode: 644
  module.run:
    - name: service.systemctl_reload
    - onchanges:
      - file: /etc/systemd/system/har.service

har_podman_container:
  podman_container.running:
    - name: har-node
    - image: har:latest
    - ports:
      - "4000:4000"
      - "9100-9199:9100-9199"
    - environment:
      - RELEASE_NODE: "har@{{ grains['fqdn'] }}"
      - RELEASE_COOKIE: "{{ pillar['har']['cookie'] }}"
      - HAR_CLUSTER_NODES: "{{ pillar['har']['cluster_nodes'] }}"
    - volumes:
      - /opt/har/config:/app/config:ro
      - /opt/har/data:/app/data:rw
      - /opt/har/logs:/app/logs:rw
    - restart_policy: always
    - require:
      - file: har_config
      - user: har_user
```

**Pillar Data:**

```yaml
# /srv/pillar/har.sls
har:
  cookie: "{{ salt['cmd.shell']('openssl rand -base64 32') }}"
  cluster_nodes: "har1@node1.local,har2@node2.local,har3@node3.local"
  security_tier: industrial
  ipfs_api: "http://localhost:5001"

  tls:
    cert: /opt/har/certs/server.crt
    key: /opt/har/certs/server.key
    ca: /opt/har/certs/ca.crt
```

### 3. Build HAR Container

**Containerfile (Dockerfile):**

```dockerfile
# Containerfile
FROM elixir:1.15-alpine AS builder

# Install build dependencies
RUN apk add --no-cache build-base git

# Set working directory
WORKDIR /app

# Copy mix files
COPY mix.exs mix.lock ./

# Install dependencies
RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get --only prod

# Copy source
COPY lib ./lib
COPY priv ./priv
COPY config ./config

# Build release
ENV MIX_ENV=prod
RUN mix compile && \
    mix release

# Runtime stage
FROM alpine:3.18

# Install runtime dependencies
RUN apk add --no-cache \
    ncurses-libs \
    libstdc++ \
    openssl \
    ca-certificates

# Create app user
RUN addgroup -S har && adduser -S har -G har

# Copy release from builder
WORKDIR /app
COPY --from=builder --chown=har:har /app/_build/prod/rel/har ./

USER har

EXPOSE 4000 9100-9199

CMD ["/app/bin/har", "start"]
```

**Build Image:**

```bash
# Build with Podman
podman build -t har:latest -f Containerfile .

# Tag for registry (optional)
podman tag har:latest registry.company.com/har:1.0.0

# Push to registry
podman push registry.company.com/har:1.0.0
```

### 4. Deploy with Salt

**Apply Salt state:**

```bash
# Accept minion keys
salt-key -A

# Test connectivity
salt '*' test.ping

# Deploy HAR
salt 'har*' state.apply har

# Verify deployment
salt 'har*' cmd.run 'podman ps'
```

### 5. Configure Load Balancer

**HAProxy Configuration:**

```haproxy
# /etc/haproxy/haproxy.cfg
global
    log /dev/log local0
    maxconn 4096
    user haproxy
    group haproxy
    daemon

defaults
    log     global
    mode    http
    option  httplog
    option  dontlognull
    timeout connect 5000
    timeout client  50000
    timeout server  50000

frontend har_https
    bind *:443 ssl crt /etc/haproxy/certs/har.pem
    mode http
    default_backend har_nodes

backend har_nodes
    mode http
    balance roundrobin
    option httpchk GET /health
    http-check expect status 200

    server har1 10.0.1.10:4000 check ssl verify required ca-file /etc/haproxy/certs/ca.crt
    server har2 10.0.1.11:4000 check ssl verify required ca-file /etc/haproxy/certs/ca.crt
    server har3 10.0.1.12:4000 check ssl verify required ca-file /etc/haproxy/certs/ca.crt
```

**Deploy HAProxy with Salt:**

```yaml
# /srv/salt/haproxy/haproxy.sls
haproxy_install:
  pkg.installed:
    - name: haproxy

haproxy_config:
  file.managed:
    - name: /etc/haproxy/haproxy.cfg
    - source: salt://haproxy/files/haproxy.cfg.jinja
    - template: jinja
    - user: root
    - group: root
    - mode: 644

haproxy_service:
  service.running:
    - name: haproxy
    - enable: True
    - watch:
      - file: /etc/haproxy/haproxy.cfg
```

## TLS Certificate Management

**Generate Self-Signed Certs (Development):**

```bash
#!/bin/bash
# gen_certs.sh

# CA certificate
openssl req -x509 -new -nodes -keyout ca.key -sha256 -days 3650 \
  -out ca.crt -subj "/CN=HAR CA"

# Server certificate
openssl req -new -nodes -keyout server.key \
  -out server.csr -subj "/CN=har.company.com"

openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out server.crt -days 365 -sha256

# Distribute to nodes
for node in har1 har2 har3; do
  scp ca.crt server.crt server.key $node:/opt/har/certs/
done
```

**Let's Encrypt (Production):**

```bash
# Install certbot
dnf install -y certbot

# Get certificate
certbot certonly --standalone -d har.company.com

# Auto-renewal
cat > /etc/cron.daily/certbot-renew <<EOF
#!/bin/bash
certbot renew --quiet
systemctl reload haproxy
EOF
chmod +x /etc/cron.daily/certbot-renew
```

## IPFS Cluster Setup

**Initialize IPFS Cluster:**

```bash
# Install ipfs-cluster-service
wget https://dist.ipfs.io/ipfs-cluster-service/v1.0.5/ipfs-cluster-service_v1.0.5_linux-amd64.tar.gz
tar xvf ipfs-cluster-service_v1.0.5_linux-amd64.tar.gz
cp ipfs-cluster-service/ipfs-cluster-service /usr/local/bin/

# Initialize on node 1
ipfs-cluster-service init

# Get cluster secret
CLUSTER_SECRET=$(ipfs-cluster-service -c /opt/ipfs-cluster id | grep secret)

# Copy secret to other nodes
# Start cluster
systemctl enable --now ipfs-cluster
```

**IPFS Cluster Systemd Service:**

```ini
# /etc/systemd/system/ipfs-cluster.service
[Unit]
Description=IPFS Cluster
After=network.target ipfs.service
Requires=ipfs.service

[Service]
Type=simple
User=ipfs
Group=ipfs
ExecStart=/usr/local/bin/ipfs-cluster-service daemon
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

## Monitoring & Observability

**Prometheus Exporters:**

```yaml
# docker-compose.yml (Podman Compose)
version: '3'

services:
  prometheus:
    image: prom/prometheus:latest
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus_data:/prometheus
    ports:
      - "9090:9090"

  grafana:
    image: grafana/grafana:latest
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=changeme
    volumes:
      - grafana_data:/var/lib/grafana
    ports:
      - "3000:3000"
    depends_on:
      - prometheus

volumes:
  prometheus_data:
  grafana_data:
```

**Prometheus Configuration:**

```yaml
# prometheus.yml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'har'
    static_configs:
      - targets:
        - '10.0.1.10:4000'
        - '10.0.1.11:4000'
        - '10.0.1.12:4000'

  - job_name: 'ipfs'
    static_configs:
      - targets:
        - '10.0.1.10:5001'
        - '10.0.1.11:5001'
        - '10.0.1.12:5001'
```

## Backup & Disaster Recovery

**IPFS Backup:**

```bash
#!/bin/bash
# backup_ipfs.sh

BACKUP_DIR="/backup/ipfs/$(date +%Y%m%d)"
mkdir -p "$BACKUP_DIR"

# Export IPFS data
ipfs repo stat > "$BACKUP_DIR/repo_stat.txt"
ipfs pin ls --type=recursive > "$BACKUP_DIR/pinned_objects.txt"

# Backup datastore
tar czf "$BACKUP_DIR/datastore.tar.gz" /opt/ipfs/datastore

# Upload to S3 (optional)
# aws s3 cp "$BACKUP_DIR" s3://backups/ipfs/ --recursive
```

**HAR Configuration Backup:**

```bash
#!/bin/bash
# backup_har.sh

BACKUP_DIR="/backup/har/$(date +%Y%m%d)"
mkdir -p "$BACKUP_DIR"

# Backup configs
tar czf "$BACKUP_DIR/config.tar.gz" /opt/har/config

# Backup routing table
cp /opt/har/priv/routing_table.yaml "$BACKUP_DIR/"

# Backup audit logs
tar czf "$BACKUP_DIR/logs.tar.gz" /opt/har/logs
```

**Automated Backups (Salt):**

```yaml
# /srv/salt/backups/backups.sls
backup_scripts:
  file.managed:
    - names:
      - /usr/local/bin/backup_har.sh:
        - source: salt://backups/files/backup_har.sh
      - /usr/local/bin/backup_ipfs.sh:
        - source: salt://backups/files/backup_ipfs.sh
    - mode: 755

backup_cron:
  cron.present:
    - name: /usr/local/bin/backup_har.sh
    - user: root
    - hour: 2
    - minute: 0
```

## Scaling

**Add New Node:**

```bash
# On new node
salt-minion -c /etc/salt/minion.d/har.conf

# On Salt master
salt-key -a har4.local

# Deploy HAR
salt 'har4.local' state.apply har

# Add to load balancer (automatic via Salt pillar)
salt 'haproxy*' state.apply haproxy
```

**Remove Node:**

```bash
# Drain traffic (update HAProxy)
salt 'haproxy*' cmd.run "echo 'disable server har_nodes/har3' | socat stdio /var/run/haproxy.sock"

# Stop HAR
salt 'har3.local' cmd.run 'podman stop har-node'

# Remove from cluster
salt 'har1.local' cmd.run 'curl -X POST http://localhost:4000/cluster/leave/har3@node3.local'

# Remove from Salt
salt-key -d har3.local
```

## Troubleshooting

**Common Issues:**

1. **Nodes not clustering:**
   ```bash
   # Check Erlang cookie matches
   salt 'har*' cmd.run 'cat /opt/har/data/.erlang.cookie'

   # Check network connectivity
   salt 'har*' cmd.run 'nc -zv har1.local 9100'

   # Check logs
   salt 'har*' cmd.run 'podman logs har-node'
   ```

2. **IPFS not syncing:**
   ```bash
   # Check cluster peers
   ipfs-cluster-ctl peers ls

   # Check IPFS swarm
   ipfs swarm peers

   # Manually connect
   ipfs swarm connect /ip4/10.0.1.10/tcp/4001/p2p/<peer-id>
   ```

3. **High memory usage:**
   ```bash
   # Check Erlang memory
   salt 'har*' cmd.run 'podman exec har-node /app/bin/har remote'
   # Then in Erlang shell: :erlang.memory()

   # Limit memory in Podman
   podman update --memory=2g har-node
   ```

## Security Hardening

**Firewall Rules:**

```bash
# Allow HAR API (TLS only)
firewall-cmd --permanent --add-port=4000/tcp

# Allow Erlang distribution (cluster only)
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="10.0.1.0/24" port port="9100-9199" protocol="tcp" accept'

# Allow IPFS
firewall-cmd --permanent --add-port=4001/tcp
firewall-cmd --permanent --add-port=5001/tcp

firewall-cmd --reload
```

**SELinux Policy (Rocky Linux):**

```bash
# Allow Podman to bind privileged ports
setsebool -P container_manage_cgroup on

# Custom policy for HAR
cat > har.te <<EOF
module har 1.0;
require {
    type container_t;
    type http_port_t;
    class tcp_socket name_bind;
}
allow container_t http_port_t:tcp_socket name_bind;
EOF

checkmodule -M -m -o har.mod har.te
semodule_package -o har.pp -m har.mod
semodule -i har.pp
```

## Summary

Self-hosted HAR deployment provides:
- **Full control:** No cloud vendor dependency
- **Scalability:** Horizontal scaling with OTP clustering
- **Reliability:** Multi-node HA, automated failover
- **Security:** Certificate-based auth, TLS encryption
- **Observability:** Prometheus + Grafana monitoring
- **Automation:** Salt Stack for config management

**Production Checklist:**
- [ ] TLS certificates configured
- [ ] Firewall rules applied
- [ ] Monitoring dashboards deployed
- [ ] Backup automation enabled
- [ ] Load balancer health checks passing
- [ ] Cluster nodes communicating
- [ ] IPFS cluster synced
- [ ] Security hardening applied
- [ ] Documentation updated
- [ ] Runbooks prepared

**Next:** See architecture docs for design details.
