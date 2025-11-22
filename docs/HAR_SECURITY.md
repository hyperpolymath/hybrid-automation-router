# HAR Security Architecture

**Threat Model:** Multi-tier security from development to critical infrastructure

HAR handles infrastructure automation across diverse environments - from developer laptops to industrial control systems. Security requirements vary drastically, requiring a flexible multi-tier approach.

## Security Principles

1. **Defense in Depth:** Multiple layers (network, auth, encryption, audit)
2. **Least Privilege:** Minimal permissions for operations
3. **Zero Trust:** Verify every request, never assume safety
4. **Immutable Audit:** All routing decisions logged to IPFS
5. **Fail Secure:** On error, deny access (not grant)

## Threat Model

### Assets to Protect

1. **Configuration Data:** Infrastructure definitions (may contain secrets)
2. **Routing Decisions:** Who can deploy what where
3. **Device Credentials:** Certificates, API keys
4. **Audit Logs:** Evidence for compliance/forensics
5. **HAR Control Plane:** Routing engine availability

### Threat Actors

| Actor | Capability | Motivation | Mitigation |
|-------|------------|------------|------------|
| Script kiddie | Low (automated tools) | Vandalism | Rate limiting, basic auth |
| Insider threat | Medium (legitimate access) | Sabotage, theft | Audit logging, least privilege |
| APT group | High (targeted, persistent) | Espionage, sabotage | Certificate pinning, air gaps |
| Supply chain | High (compromised vendor) | Backdoor | Code signing, reproducible builds |

### Attack Vectors

1. **MAC Spoofing:** Attacker clones device MAC address
   - **Mitigation:** MAC for discovery only, certs for auth

2. **Man-in-the-Middle:** Intercept HAR ↔ device communication
   - **Mitigation:** TLS 1.3, certificate pinning

3. **Replay Attacks:** Resend captured operations
   - **Mitigation:** Nonces, timestamps, operation IDs

4. **Privilege Escalation:** Dev device executes prod operations
   - **Mitigation:** Policy engine enforces environment boundaries

5. **Supply Chain Compromise:** Malicious parser/transformer plugin
   - **Mitigation:** Code signing, sandboxing, review process

6. **Denial of Service:** Overwhelm HAR with requests
   - **Mitigation:** Rate limiting, circuit breakers, resource quotas

## Security Tiers

HAR implements different security levels based on environment criticality:

### Tier 0: Development (Low Security)

**Use Case:** Laptop development, CI/CD testing

**Characteristics:**
- Self-signed certificates OK
- Unencrypted communication allowed (localhost)
- Minimal audit logging
- No rate limiting

**Configuration:**
```elixir
config :har, security_tier: :development,
  require_tls: false,
  accept_self_signed: true,
  audit_logging: false,
  rate_limiting: false
```

**Threats Accepted:** Low - isolated environment, no production impact

### Tier 1: Consumer IoT (Medium Security)

**Use Case:** Smart homes, wearables, consumer devices

**Characteristics:**
- Device certificates required (manufacturer-issued)
- TLS 1.3 encryption mandatory
- Basic audit logging (local)
- Rate limiting per device

**Configuration:**
```elixir
config :har, security_tier: :iot,
  require_tls: true,
  require_device_cert: true,
  cert_issuer: ["Philips Hue CA", "Google Nest CA"],
  audit_logging: :local,
  rate_limit: {100, :per_minute}
```

**Certificate Validation:**
```elixir
def validate_iot_cert(cert) do
  with :ok <- verify_not_expired(cert),
       :ok <- verify_issuer(cert, allowed_issuers()),
       :ok <- verify_revocation(cert),
       :ok <- verify_key_usage(cert, [:digital_signature]) do
    {:ok, extract_device_id(cert)}
  end
end
```

### Tier 2: Industrial (High Security)

**Use Case:** Factory automation, critical infrastructure (non-safety)

**Characteristics:**
- Mutual TLS (both HAR and device authenticate)
- VPN required (isolated network)
- Audit logging to IPFS (immutable)
- Certificate pinning
- Operator approval for sensitive operations

**Configuration:**
```elixir
config :har, security_tier: :industrial,
  require_mutual_tls: true,
  require_vpn: true,
  allowed_vpn_subnets: ["10.100.0.0/16"],
  cert_pinning: true,
  audit_logging: :ipfs,
  operator_approval: [:firmware_update, :safety_config]
```

**Mutual TLS:**
```elixir
# HAR presents cert to device, device presents cert to HAR
ssl_opts = [
  verify: :verify_peer,
  cacertfile: ca_cert_path(),
  certfile: har_cert_path(),
  keyfile: har_key_path(),
  fail_if_no_peer_cert: true,
  verify_fun: {&verify_device_cert/3, []}
]
```

### Tier 3: Critical Infrastructure (Maximum Security)

**Use Case:** Power plants, water treatment, medical devices, aviation

**Characteristics:**
- HSM-backed certificates (tamper-proof keys)
- Air-gapped network (no internet)
- Formal verification of routing rules
- Two-person rule (dual approval)
- Immutable audit logs (IPFS + offline storage)
- Annual penetration testing

**Configuration:**
```elixir
config :har, security_tier: :critical,
  require_hsm: true,
  hsm_type: :yubikey_5,
  air_gapped: true,
  require_dual_approval: true,
  audit_logging: [:ipfs, :offline_archive],
  formal_verification: true,
  max_operation_rate: {10, :per_hour}  # Deliberate slowness
```

**HSM Integration:**
```elixir
# Private keys never leave HSM
defmodule HAR.Security.HSM do
  def sign_operation(operation, hsm_device) do
    operation_hash = :crypto.hash(:sha256, :erlang.term_to_binary(operation))

    # HSM performs signing internally
    {:ok, signature} = YubiHSM.sign(hsm_device, operation_hash)

    %SignedOperation{
      operation: operation,
      signature: signature,
      signer: hsm_device_id(hsm_device),
      timestamp: DateTime.utc_now()
    }
  end
end
```

**Dual Approval:**
```elixir
# Two operators must approve critical operations
def execute_critical_operation(operation) do
  with {:ok, approval1} <- request_approval(operation, operator: 1),
       {:ok, approval2} <- request_approval(operation, operator: 2),
       :ok <- verify_distinct_operators(approval1, approval2),
       :ok <- verify_recent_approvals(approval1, approval2, max_age: 300) do
    execute(operation)
  end
end
```

## Authentication & Authorization

### Device Authentication

**Certificate-Based (Primary):**

```elixir
# Device presents X.509 certificate
# HAR validates:
# 1. Signature by trusted CA
# 2. Not expired
# 3. Not revoked (CRL/OCSP)
# 4. Subject matches expected device
# 5. Extended Key Usage: clientAuth

defmodule HAR.Security.DeviceAuth do
  def authenticate(cert_der) do
    cert = X509.Certificate.from_der!(cert_der)

    with :ok <- verify_signature(cert),
         :ok <- verify_validity_period(cert),
         :ok <- verify_not_revoked(cert),
         {:ok, device_id} <- extract_device_id(cert),
         :ok <- verify_mac_binding(device_id, client_mac()) do
      {:ok, %DeviceIdentity{id: device_id, cert: cert}}
    end
  end

  defp verify_mac_binding(device_id, client_mac) do
    # Defense in depth: verify MAC matches registered device
    # NOT primary auth (spoofable) but additional check
    registered_mac = DeviceRegistry.get_mac(device_id)

    if String.downcase(client_mac) == String.downcase(registered_mac) do
      :ok
    else
      Logger.warn("MAC mismatch for device #{device_id}: #{client_mac} != #{registered_mac}")
      {:error, :mac_mismatch}
    end
  end
end
```

**API Keys (Secondary, for development only):**

```elixir
# Scoped API keys for testing
%APIKey{
  key: "har_dev_abc123...",
  scopes: [:read_config, :route_operations],
  environment: :development,
  expires_at: ~U[2024-12-31 23:59:59Z]
}
```

### Operator Authentication

**Human Users (HAR Dashboard/CLI):**

```elixir
# OIDC integration for SSO
config :har, :auth,
  provider: :oidc,
  issuer: "https://sso.company.com",
  client_id: "har-production",
  scopes: ["openid", "profile", "groups"]

# Group-based RBAC
%User{
  id: "alice@company.com",
  groups: ["har-operators", "factory-floor-admin"],
  permissions: [:route_operations, :view_audit_logs, :manage_devices]
}
```

### Authorization (Policy-Based)

**OPA Integration (Open Policy Agent):**

```rego
# Rego policy: Only industrial-group can route to industrial subnet
package har.authz

import future.keywords.if

allow if {
  input.operation.target.subnet == "2001:db8:3::/48"
  "industrial-operators" in input.user.groups
}

# Deny firmware updates outside maintenance window
deny if {
  input.operation.type == "firmware_update"
  not maintenance_window(input.timestamp)
}

maintenance_window(ts) if {
  # Sundays 2-4 AM UTC
  day_of_week(ts) == 0
  hour(ts) >= 2
  hour(ts) < 4
}
```

**Enforcement in HAR:**

```elixir
def authorize_operation(operation, user) do
  opa_input = %{
    operation: operation,
    user: user,
    timestamp: DateTime.utc_now()
  }

  case OPA.evaluate("har/authz/allow", opa_input) do
    {:ok, true} -> :ok
    {:ok, false} -> {:error, :unauthorized}
    {:error, _} = error -> error
  end
end
```

## Encryption

### In Transit

**TLS 1.3 for all network communication:**

```elixir
# HAR ↔ Device
ssl_opts = [
  versions: [:"tlsv1.3"],
  ciphers: [
    # Only strong ciphers (forward secrecy)
    "TLS_AES_256_GCM_SHA384",
    "TLS_CHACHA20_POLY1305_SHA256"
  ],
  verify: :verify_peer,
  cacertfile: ca_cert_path(),
  certfile: client_cert_path(),
  keyfile: client_key_path()
]
```

**Certificate Pinning (High Security):**

```elixir
# Pin expected certificate hash
expected_hash = "sha256:a3b4c5d6e7f8..."

def verify_pinned_cert(cert) do
  actual_hash = "sha256:" <> Base.encode16(:crypto.hash(:sha256, cert))

  if actual_hash == expected_hash do
    :ok
  else
    {:error, :cert_pin_mismatch}
  end
end
```

### At Rest

**IPFS Content Addressing (Integrity):**

```elixir
# Store configs in IPFS - CID is cryptographic hash
{:ok, cid} = IPFS.add(config_data)

# CID = "QmXoypizjW3WknFiJnKLwHCnL72vedxjQkDDP1mXWo6uco"
# Tamper-proof: any change = different CID
```

**Secrets Encryption (Vault Integration):**

```elixir
# Never store secrets in configs
# Use references, fetch from vault

# ❌ BAD
database_password: "super_secret_123"

# ✅ GOOD
database_password: "vault://prod/db/password"

# HAR fetches from Vault at runtime
def resolve_secrets(config) do
  Enum.map(config, fn {key, value} ->
    case value do
      "vault://" <> path ->
        {key, Vault.read!(path)}
      _ ->
        {key, value}
    end
  end)
end
```

## Audit Logging

**Immutable Logs to IPFS:**

```elixir
defmodule HAR.Audit do
  def log_routing_decision(decision) do
    entry = %AuditEntry{
      id: UUID.uuid4(),
      timestamp: DateTime.utc_now(),
      event_type: :routing_decision,
      operation: decision.operation,
      backend: decision.backend,
      user: current_user(),
      approved_by: decision.approvals,
      policies_applied: decision.policies
    }

    # Sign entry
    signed_entry = sign_with_har_key(entry)

    # Store in IPFS (immutable)
    {:ok, cid} = IPFS.add(:erlang.term_to_binary(signed_entry))

    # Also log locally for fast queries
    AuditLog.insert(entry, ipfs_cid: cid)

    # Emit telemetry
    :telemetry.execute([:har, :audit, :logged], %{}, %{event_type: :routing_decision})
  end
end
```

**Query Audit Trail:**

```elixir
# Local DB for recent logs (fast)
recent = AuditLog.query(user: "alice@company.com", since: ~U[2024-01-01 00:00:00Z])

# IPFS for historical/forensics (slow but tamper-proof)
historical = recent
|> Enum.map(&IPFS.cat(&1.ipfs_cid))
|> Enum.map(&:erlang.binary_to_term/1)
|> Enum.filter(&verify_signature/1)
```

**Compliance Reports:**

```elixir
# Generate report for auditors
def generate_compliance_report(start_date, end_date) do
  entries = AuditLog.query(since: start_date, until: end_date)

  %ComplianceReport{
    period: {start_date, end_date},
    total_operations: length(entries),
    by_user: Enum.frequencies_by(entries, & &1.user),
    by_type: Enum.frequencies_by(entries, & &1.event_type),
    violations: Enum.filter(entries, & &1.policy_violation),
    ipfs_root: build_merkle_tree(entries)  # Verify integrity
  }
end
```

## Input Validation & Sandboxing

**Parser Sandboxing:**

```elixir
# Untrusted configs parsed in isolated process with resource limits
def parse_untrusted(format, content) do
  Task.Supervisor.async_nolink(HAR.ParserSandbox, fn ->
    # Set resource limits
    Process.flag(:max_heap_size, 100_000_000)  # 100MB
    Process.flag(:trap_exit, true)

    # Set timeout
    timeout_ref = Process.send_after(self(), :timeout, 30_000)

    result = HAR.DataPlane.Parser.parse(format, content)

    Process.cancel_timer(timeout_ref)
    result
  end)
  |> Task.await(35_000)
rescue
  e -> {:error, {:parse_failed, e}}
end
```

**Operation Validation:**

```elixir
# Validate operations before execution
def validate_operation(operation) do
  with :ok <- validate_type(operation.type),
       :ok <- validate_params(operation.params),
       :ok <- validate_target(operation.target),
       :ok <- check_dangerous_patterns(operation) do
    :ok
  end
end

defp check_dangerous_patterns(operation) do
  # Detect potentially malicious operations
  dangerous = [
    ~r/rm -rf \/$/,           # Destructive commands
    ~r/curl .+ \| bash/,      # Pipe to shell
    ~r/wget .+ \| sh/,
    ~r/__import__\('os'\)/    # Python code injection
  ]

  content = :erlang.term_to_binary(operation)

  if Enum.any?(dangerous, &Regex.match?(&1, content)) do
    {:error, :dangerous_pattern_detected}
  else
    :ok
  end
end
```

## Rate Limiting & DDoS Protection

**Token Bucket per Client:**

```elixir
defmodule HAR.RateLimit do
  use GenServer

  # 100 requests per minute per client
  @bucket_size 100
  @refill_rate {100, 60_000}  # 100 tokens per 60 seconds

  def check_rate(client_id) do
    GenServer.call(__MODULE__, {:check, client_id})
  end

  def handle_call({:check, client_id}, _from, state) do
    bucket = Map.get(state.buckets, client_id, @bucket_size)

    if bucket > 0 do
      new_state = put_in(state.buckets[client_id], bucket - 1)
      {:reply, :ok, new_state}
    else
      {:reply, {:error, :rate_limit_exceeded}, state}
    end
  end
end
```

**Circuit Breaker:**

```elixir
# If backend fails 5 times in 30 sec, stop sending requests for 60 sec
%CircuitBreaker{
  failure_threshold: 5,
  window: 30_000,
  timeout: 60_000,
  state: :closed  # :closed, :open, :half_open
}
```

## Security Monitoring

**Anomaly Detection:**

```elixir
# Detect unusual patterns
:telemetry.attach("security-monitor", [:har, :routing, :decision], fn event, measurements, metadata, _config ->
  # Unusual: dev device routing to prod subnet
  if metadata.device_env == :dev and metadata.target_env == :prod do
    SecurityAlert.raise(:environment_boundary_violation, metadata)
  end

  # Unusual: spike in firmware updates
  if event == :firmware_update and spike_detected?(measurements) do
    SecurityAlert.raise(:firmware_update_spike, measurements)
  end
end, nil)
```

**Intrusion Detection:**

```elixir
# Failed auth attempts
:telemetry.execute([:har, :auth, :failed], %{}, %{client: client_ip, reason: :invalid_cert})

# Threshold: 5 failures in 5 minutes = block
if failed_auth_count(client_ip, window: 300) >= 5 do
  Firewall.block(client_ip, duration: 3600)
end
```

## Incident Response

**Playbook:**

1. **Detection:** Anomaly triggers alert
2. **Containment:** Circuit breaker blocks traffic
3. **Investigation:** Query audit logs from IPFS
4. **Remediation:** Revoke compromised certs, patch vulnerability
5. **Recovery:** Gradually restore traffic
6. **Lessons Learned:** Update policies, improve detection

**Automated Response:**

```elixir
def handle_security_incident(alert) do
  case alert.severity do
    :critical ->
      # Shut down affected nodes immediately
      affected_nodes = identify_affected_nodes(alert)
      Enum.each(affected_nodes, &Node.stop/1)
      notify_security_team(alert)

    :high ->
      # Block malicious client
      block_client(alert.client_id)
      notify_security_team(alert)

    :medium ->
      # Log and monitor
      log_alert(alert)
      increase_monitoring(alert.category)
  end
end
```

## Summary

HAR security is multi-tiered:

- **Development:** Low security, fast iteration
- **Consumer IoT:** Medium security, certificate-based
- **Industrial:** High security, mutual TLS + VPN
- **Critical Infrastructure:** Maximum security, HSM + dual approval

**Key Mechanisms:**
- **Certificates for auth** (NOT MAC addresses)
- **TLS 1.3 encryption**
- **Immutable audit logs** (IPFS)
- **Policy enforcement** (OPA)
- **Rate limiting & sandboxing**
- **Intrusion detection & response**

**Next:** See STANDARDIZATION_STRATEGY.md for path to IETF RFC.
