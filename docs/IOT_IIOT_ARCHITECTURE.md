# HAR IoT/IIoT Architecture

**Purpose:** Scale HAR to billions of IoT/IIoT devices using IPv6 + MAC addressing

Traditional IaC tools target servers (thousands to millions). HAR extends to IoT sensors and industrial robots (billions of devices) by treating them as first-class routing targets.

## Problem Space

**IoT/IIoT Characteristics:**
- **Scale:** Billions of devices (smart homes, factories, cities)
- **Heterogeneity:** Diverse hardware (ARM, RISC-V, x86), OS (Linux, FreeRTOS, bare metal)
- **Constraints:** Limited CPU/memory/bandwidth
- **Lifecycle:** Decades in field (can't rewrite configs)
- **Security:** Physical access risk, supply chain attacks

**Traditional IaC Limitations:**
- IPv4 exhaustion (4.3B addresses total)
- No device type classification
- Server-centric (no edge considerations)
- Heavy agents (Ansible, Puppet require Python/Ruby)

## HAR Solution: IPv6 + MAC Addressing

### IPv6 for Classification

**Use IPv6 subnets to encode device types:**

```
2001:db8::/32 - HAR-managed infrastructure

  2001:db8:1::/48 - Servers (traditional IaC)
    2001:db8:1:0001::/64 - Web servers
    2001:db8:1:0002::/64 - Database servers
    2001:db8:1:0003::/64 - Cache servers

  2001:db8:2::/48 - IoT devices (consumer)
    2001:db8:2:0001::/64 - Smart lights
    2001:db8:2:0002::/64 - Thermostats
    2001:db8:2:0003::/64 - Security cameras

  2001:db8:3::/48 - IIoT devices (industrial)
    2001:db8:3:0001::/64 - PLC controllers
    2001:db8:3:0002::/64 - Industrial robots
    2001:db8:3:0003::/64 - Sensors (temp/pressure/flow)

  2001:db8:4::/48 - Edge gateways
    2001:db8:4:0001::/64 - Factory floor gateways
    2001:db8:4:0002::/64 - Smart building gateways
```

**Routing Table Pattern Matching:**

```yaml
routes:
  # All IoT devices use minimal systemd
  - pattern:
      target:
        ipv6_prefix: "2001:db8:2::/48"
    backends:
      - name: systemd_minimal
        priority: 100

  # Industrial PLCs need high-security backend
  - pattern:
      target:
        ipv6_prefix: "2001:db8:3:0001::/64"
    backends:
      - name: secure_plc_manager
        priority: 100
        require_auth: certificate
        security_tier: critical
```

**Benefits:**
- **128-bit address space:** 340 undecillion devices
- **Hierarchical routing:** Subnet = device type
- **No NAT required:** End-to-end connectivity
- **Autoconfiguration:** SLAAC for plug-and-play

### MAC for Discovery + Binding

**MAC addresses identify physical devices:**

```elixir
defmodule HAR.IoT.DeviceRegistry do
  # MAC → Device metadata
  def register_device(mac, metadata) do
    %Device{
      mac: "00:1A:2B:3C:4D:5E",
      ipv6: "2001:db8:2:0001::5e",
      type: :smart_light,
      manufacturer: "Philips",
      model: "Hue",
      firmware: "1.2.3",
      capabilities: [:on_off, :dimming, :color],
      security_tier: :medium
    }
  end
end
```

**Discovery via mDNS/DNS-SD:**

```elixir
# Device advertises via multicast DNS
# _har._tcp.local. PTR smart-light-5e._har._tcp.local.
# smart-light-5e._har._tcp.local. SRV 0 0 4000 2001:db8:2:0001::5e
# smart-light-5e._har._tcp.local. TXT "type=smart_light" "fw=1.2.3"
```

**IMPORTANT: MAC ≠ Authentication**

```elixir
# ❌ WRONG: MAC-based auth (spoofable!)
def authenticate(mac) do
  {:ok, get_device(mac)}
end

# ✅ CORRECT: Certificate-based auth, MAC for binding
def authenticate(cert) do
  with {:ok, device} <- verify_certificate(cert),
       :ok <- verify_mac_binding(device, client_mac) do
    {:ok, device}
  end
end
```

**Why MAC Can't Be Primary Auth:**
- **Spoofable:** Attacker can clone MAC address
- **No secrets:** MAC is public, broadcast on network
- **Physical access:** Read from device label

**Use MAC For:**
- Discovery (mDNS, DHCP)
- Binding cert to physical device (defense-in-depth)
- Asset tracking (inventory management)
- Network segmentation (VLAN assignment)

## Device Capability Advertisement

**DNS TXT Records (or custom HARDEV record type):**

```dns
; Standard TXT approach
smart-light-5e._har._tcp.local. 120 IN TXT (
  "version=1"
  "type=smart_light"
  "capabilities=on_off,dimming,color"
  "protocols=coap,mqtt"
  "auth=certificate"
  "fw=1.2.3"
  "mfr=Philips"
)

; Future: Custom HARDEV RR type
smart-light-5e._har._tcp.local. 120 IN HARDEV (
  type: smart_light
  capabilities: [on_off, dimming, color]
  protocols: [coap, mqtt]
  auth: certificate
  firmware: "1.2.3"
)
```

**HAR queries device capabilities before routing:**

```elixir
def route_to_device(operation, ipv6) do
  {:ok, capabilities} = DNS.query_capabilities(ipv6)

  if operation.required_capability in capabilities do
    route_to(operation, ipv6)
  else
    {:error, :capability_not_supported}
  end
end
```

## Lightweight Agent Architecture

**Problem:** Full Ansible/Salt agents too heavy for constrained devices

**Solution:** Minimal HAR agent (Elixir or C)

### Elixir Agent (for Linux-capable devices)

```elixir
defmodule HAR.Agent.IoT do
  use GenServer

  # Minimal footprint: ~10MB memory
  # Connects to HAR cluster via TLS
  # Receives operations, executes locally

  def handle_cast({:execute, operation}, state) do
    case operation.type do
      :package_install ->
        System.cmd("opkg", ["install", operation.params.name])
      :service_restart ->
        System.cmd("systemctl", ["restart", operation.params.name])
      :file_write ->
        File.write!(operation.params.path, operation.params.content)
    end

    {:noreply, state}
  end
end
```

### C Agent (for constrained devices)

```c
// Bare-metal or FreeRTOS
// ~100KB binary, <1MB RAM

#include "har_agent.h"

void setup() {
  har_connect("2001:db8:4:0001::1", 4000, cert, key);
}

void loop() {
  har_operation_t op;
  if (har_receive(&op, TIMEOUT_MS)) {
    execute_operation(&op);
    har_ack(op.id);
  }
}
```

### Protocol: HAR Control Protocol (HARCP)

**Lightweight binary protocol over CoAP or MQTT:**

```
┌─────────────────────────────────────────┐
│         HARCP Packet Format             │
├─────────────────────────────────────────┤
│ Version (1 byte) | Type (1 byte)        │
│ Operation ID (16 bytes UUID)            │
│ Payload Length (4 bytes)                │
│ Payload (variable)                      │
│ Signature (64 bytes Ed25519)            │
└─────────────────────────────────────────┘
```

**Operation Types:**
- 0x01: Execute (HAR → Device)
- 0x02: Ack (Device → HAR)
- 0x03: Status (Device → HAR)
- 0x04: Capability Query (HAR → Device)
- 0x05: Capability Response (Device → HAR)

## Security Tiers

**Different security requirements by device class:**

| Tier | Device Type | Auth | Encryption | Update Freq |
|------|-------------|------|------------|-------------|
| Low | Dev/Test | Self-signed | Optional | On-demand |
| Medium | Consumer IoT | Device cert | TLS 1.3 | Weekly |
| High | Industrial | Mutual TLS | TLS 1.3 + VPN | Monthly |
| Critical | Safety systems | HSM-backed | TLS 1.3 + VPN + Air-gap | Quarterly |

**Implementation:**

```elixir
defmodule HAR.Security.DeviceAuth do
  def authenticate(ipv6, cert) do
    tier = security_tier_from_ipv6(ipv6)

    case tier do
      :critical ->
        # HSM verification + offline signing
        verify_hsm_cert(cert) and verify_air_gap_signature(cert)
      :high ->
        # Mutual TLS + VPN check
        verify_cert_chain(cert) and verify_vpn_active(ipv6)
      :medium ->
        # Standard TLS cert
        verify_cert_chain(cert)
      :low ->
        # Self-signed OK for dev
        verify_self_signed(cert)
    end
  end

  defp security_tier_from_ipv6(ipv6) do
    case ipv6 do
      "2001:db8:3:0001:" <> _ -> :critical  # PLCs
      "2001:db8:3:" <> _ -> :high           # Industrial
      "2001:db8:2:" <> _ -> :medium         # Consumer IoT
      _ -> :low
    end
  end
end
```

## Edge Computing Integration

**HAR nodes at edge for low latency:**

```
┌──────────────────────────────────────────────────────────────┐
│                    Cloud (Central HAR)                        │
│  Policy mgmt, logging, dashboards                            │
└───────────────────────┬──────────────────────────────────────┘
                        │ (slow link, infrequent sync)
┌───────────────────────┴──────────────────────────────────────┐
│              Edge Gateway (Local HAR Node)                    │
│  Fast routing, local caching, offline capable                │
└───────────────────────┬──────────────────────────────────────┘
                        │ (fast link, local network)
         ┌──────────────┼──────────────┬──────────────┐
         ↓              ↓              ↓              ↓
    ┌────────┐     ┌────────┐     ┌────────┐     ┌────────┐
    │ Device │     │ Device │     │ Device │     │ Device │
    └────────┘     └────────┘     └────────┘     └────────┘
```

**Offline Operation:**

```elixir
# Edge gateway caches routing decisions
# If cloud unreachable, use cached routes
def route_with_fallback(operation) do
  case route_via_cloud(operation) do
    {:ok, decision} ->
      cache_decision(operation, decision)
      decision
    {:error, :cloud_unreachable} ->
      cached_decision(operation) || local_default_route(operation)
  end
end
```

## Industrial Use Cases

### Factory Floor Automation

**Scenario:** Configure 10,000 industrial robots

```elixir
# Ansible playbook targets robot subnet
- hosts: 2001:db8:3:0002::/64
  tasks:
    - name: Update firmware
      har.firmware:
        version: "2.1.0"
        checksum: sha256:abc123...

    - name: Configure safety limits
      har.config:
        max_speed: 1.5  # m/s
        emergency_stop: true
```

**HAR transforms to robot-specific protocol:**

```elixir
# Parser → Semantic graph
%Operation{
  type: :firmware_update,
  params: %{version: "2.1.0", checksum: "sha256:abc123..."},
  targets: ipv6_subnet_to_device_list("2001:db8:3:0002::/64")
}

# Router → Select robot backend
backend = %Backend{
  name: :industrial_robot_manager,
  protocol: :modbus_tcp,
  security_tier: :critical
}

# Transformer → Modbus TCP commands
modbus_commands = [
  %ModbusCommand{function: 0x10, address: 0x1000, value: firmware_blob}
]
```

### Smart Building Management

**Scenario:** Dim all lights at night

```yaml
# Salt state for smart lights
dim_lights:
  har.smart_light.dimming:
    - targets: 2001:db8:2:0001::/64
    - brightness: 30
    - schedule: "sunset to sunrise"
```

**HAR routes via CoAP:**

```elixir
# Transformer generates CoAP requests
devices = ipv6_subnet_scan("2001:db8:2:0001::/64")

Enum.each(devices, fn device ->
  CoAP.put("coap://[#{device}]/light/brightness", "30")
end)
```

## Performance at Scale

**Challenge:** Route to 1 billion devices

**Solution: Hierarchical Routing**

```elixir
# Don't enumerate all devices - use subnet routing
# Instead of: route_to([device1, device2, ..., device_1b])
# Do: route_to_subnet("2001:db8:2::/48")

def route_to_subnet(subnet) do
  # HAR edge gateways handle subnet-local routing
  # Central HAR only routes to gateways
  gateway = gateway_for_subnet(subnet)
  route_to_gateway(gateway, subnet)
end
```

**Caching:**
```elixir
# Cache device capabilities (TTL: 1 hour)
# Reduces DNS queries from billions to thousands/sec

%Cache{
  key: ipv6_address,
  value: capabilities,
  ttl: 3600
}
```

**Batching:**
```elixir
# Batch operations to same subnet
# Single multicast packet instead of unicast to each

def execute_batch(operations) do
  operations
  |> Enum.group_by(&subnet/1)
  |> Enum.map(fn {subnet, ops} ->
    multicast_to_subnet(subnet, ops)
  end)
end
```

## Monitoring & Telemetry

**Device Metrics:**
```elixir
:telemetry.execute(
  [:har, :iot, :device, :operation],
  %{latency: 50, success: true},
  %{device_type: :smart_light, subnet: "2001:db8:2:0001::/64"}
)
```

**Dashboards:**
- Heatmap: Device distribution by subnet
- Time series: Operations/sec by device type
- Alerts: Offline devices, failed operations
- Compliance: Certificate expiry, firmware versions

## Future Enhancements

1. **Matter Protocol:** Support Thread/Matter for smart homes
2. **LoRaWAN Integration:** Low-power wide-area networks
3. **5G Network Slicing:** QoS for critical operations
4. **AI-Based Anomaly Detection:** Unusual device behavior
5. **Blockchain Audit Trail:** Immutable device config history

## Summary

HAR scales to IoT/IIoT by:
- **IPv6 subnets:** Classify billions of devices hierarchically
- **MAC discovery:** Device identification (not auth!)
- **Lightweight agents:** Minimal footprint for constrained hardware
- **Certificate auth:** Secure even with physical access threats
- **Edge computing:** Low latency via local HAR nodes
- **Hierarchical routing:** Subnet-level routing for efficiency

**Next:** See HAR_SECURITY.md for detailed threat model.
