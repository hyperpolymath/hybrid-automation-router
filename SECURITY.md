# Security Policy

## Supported Versions

HAR is currently in early development (POC phase). Security updates will be provided for:

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |

## Reporting a Vulnerability

**DO NOT** open public GitHub issues for security vulnerabilities.

Instead, please report security vulnerabilities via:

### Preferred Method: Private Security Advisory

1. Go to the [Security tab](../../security/advisories)
2. Click "Report a vulnerability"
3. Provide detailed information about the vulnerability

### Alternative: Email

Send details to: [security contact to be added]

Include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if available)

### What to Expect

- **Acknowledgment:** Within 48 hours
- **Initial Assessment:** Within 7 days
- **Fix Timeline:** Varies by severity
  - **Critical:** 7 days
  - **High:** 14 days
  - **Medium:** 30 days
  - **Low:** 90 days

## Security Features

HAR implements multi-tier security:

### Tier 0: Development (Low Security)
- Self-signed certificates acceptable
- Unencrypted localhost communication
- Minimal audit logging

### Tier 1: Consumer IoT (Medium Security)
- Device certificates required
- TLS 1.3 encryption mandatory
- Basic audit logging
- Rate limiting per device

### Tier 2: Industrial (High Security)
- Mutual TLS required
- VPN/isolated network required
- Certificate pinning
- Immutable audit logs (IPFS)
- Operator approval for sensitive operations

### Tier 3: Critical Infrastructure (Maximum Security)
- HSM-backed certificates
- Air-gapped network
- Formal verification of routing rules
- Two-person rule (dual approval)
- Annual penetration testing

## Threat Model

See [docs/HAR_SECURITY.md](docs/HAR_SECURITY.md) for comprehensive threat model including:
- Assets to protect
- Threat actors (script kiddie → APT)
- Attack vectors and mitigations
- Defense in depth strategies

## Security Best Practices

### For Users

1. **Never commit secrets to configs**
   - Use vault references: `vault://prod/db/password`
   - Never use plain text passwords

2. **Use appropriate security tier**
   - Development: Use tier 0
   - Production: Use tier 2+
   - Critical systems: Use tier 3

3. **Keep HAR updated**
   - Security patches released promptly
   - Subscribe to security advisories

4. **Validate all inputs**
   - Use HAR's built-in validation
   - Sandbox untrusted configs

### For Contributors

1. **No arbitrary code execution**
   - Parsers must be sandboxed
   - Resource limits enforced
   - Timeout guards required

2. **Input validation**
   - Validate all external inputs
   - Use type safety (Elixir specs)
   - Property-based testing for parsers

3. **Dependency security**
   - Minimal dependencies
   - Regular security audits (`mix audit`)
   - Pin versions in `mix.lock`

4. **Code review**
   - All security-sensitive changes require review
   - Security champion approval for auth/crypto

## Known Security Considerations

### Current Limitations (POC Phase)

- ⚠️ TLS implementation not yet complete
- ⚠️ Certificate validation stubs only
- ⚠️ IPFS audit logging not implemented
- ⚠️ Policy engine not yet built
- ⚠️ Rate limiting not implemented

**Do not use in production until v1.0 release.**

### Planned Security Features

- [ ] Complete TLS 1.3 implementation
- [ ] Certificate pinning
- [ ] IPFS immutable audit logs
- [ ] Policy engine (OPA integration)
- [ ] Rate limiting and DDoS protection
- [ ] HSM integration
- [ ] Formal verification (TLA+ specs)

## Security Certifications

None yet (POC phase).

**Planned:**
- SOC 2 Type II (post-1.0)
- Common Criteria EAL4+ (for critical infrastructure use)
- FIPS 140-2 compliance (crypto modules)

## Bug Bounty Program

Not currently active (POC phase).

**Planned:** Bug bounty program launch with v1.0 release.

## Responsible Disclosure

We follow coordinated vulnerability disclosure:

1. Reporter notifies HAR security team privately
2. HAR confirms vulnerability
3. HAR develops and tests fix
4. HAR releases patch
5. HAR publishes security advisory
6. Reporter receives credit (if desired)

**Embargo period:** 90 days (negotiable for critical issues)

## Security Contacts

- **Lead Security Contact:** [To be assigned]
- **Security Team:** [To be formed]

## Acknowledgments

We thank the following security researchers for responsible disclosure:

_(No reports yet - this is a new project)_

## Further Reading

- [HAR Security Architecture](docs/HAR_SECURITY.md)
- [Threat Model](docs/HAR_SECURITY.md#threat-model)
- [Multi-Tier Security](docs/HAR_SECURITY.md#security-tiers)
- [Audit Logging](docs/HAR_SECURITY.md#audit-logging)

---

Last updated: 2024-01-22
