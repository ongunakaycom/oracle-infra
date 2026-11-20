# DAST & Network Audit — Remediation Runbook

This document maps the findings of the external DAST/network audit to the code
changes in this repository and to the manual steps that remain on the live OCI
tenant.

| Finding | Severity | Status | Fix |
| --- | --- | --- | --- |
| Port 22 reachable from `0.0.0.0/0` | Medium | Diagnose + guard | [1. Public SSH](#1-public-ssh-port-22) |
| Missing `Content-Security-Policy` / `Permissions-Policy` | Low | Fixed in repository | [2. Security headers](#2-security-headers) |
| No rate limiting on `/api/login` | High | Fixed in repository | [3. Login rate limiting](#3-login-rate-limiting) |

The application fixes take effect after the next deploy to `main`/`master`.
Terraform-only changes take effect after `terraform apply`.

---

## 1. Public SSH (port 22)

### Why the scan still sees port 22

`security.tf` restricts SSH to the VCN CIDR (`10.0.0.0/16`) in the **NSG**.
OCI evaluates NSGs **and** the subnet's Security Lists together, and the union
is what takes effect. A Security List attached to the subnet with an ingress
rule `0.0.0.0/0 → TCP 22` therefore re-opens the port regardless of the NSG.
The console-created default security list commonly contains exactly that rule.

The NSG cannot subtract a rule that a Security List allows — the rule has to be
removed from (or narrowed in) the Security List itself.

### Diagnose

`security.tf` now reads the subnet and its Security Lists and emits a plan-time
warning when a public SSH rule is found:

```bash
terraform plan
# Warning: Check block "ssh_not_exposed_to_internet"
# Subnet'e bağlı şu Security List(ler) 22/tcp portunu internete açıyor: ...
```

`check` blocks are warnings, not hard failures, so a plan that trips this check
must be reviewed before apply.

You can also confirm from the CLI:

```bash
# Security lists used by the instance subnet
oci network subnet get --subnet-id "$SUBNET_OCID" \
  --query 'data."security-list-ids"' --output json

# Current ingress rules of each list (look for protocol 6 / 0.0.0.0/0 / port 22)
oci network security-list get --security-list-id "$SECURITY_LIST_OCID" \
  --query 'data."ingress-security-rules"' --output json
```

### Fix (live tenant)

1. List the rules and keep everything except the public SSH rule:

   ```bash
   oci network security-list get --security-list-id "$SECURITY_LIST_OCID" \
     --query 'data."ingress-security-rules"' --output json > ingress.json
   ```

2. Remove (or narrow the source of) the entry that matches
   `source == "0.0.0.0/0"` and `tcpOptions.destinationPortRange` covering `22`.
   Never leave the port open to `0.0.0.0/0`; if direct SSH is required as a
   temporary break-glass path, narrow it to a single `/32` operator address and
   remove it again afterwards.

3. Apply the edited list:

   ```bash
   oci network security-list update --security-list-id "$SECURITY_LIST_OCID" \
     --ingress-security-rules file://ingress.json
   ```

4. Verify from outside the VCN:

   ```bash
   nmap -Pn -p 22,80,443 oracle-infra.duckdns.org
   ```

   Expected: `22/tcp filtered`, `80/tcp open`, `443/tcp open`.

Administrative access stays available through the OCI Bastion Service
(`bastion.tf`), whose client allow-list is `bastion_allowed_cidrs`.

> If the Security List was created outside Terraform, keep it that way or import
> it (`terraform import oci_core_security_list.<name> <ocid>`) before managing it
> in code. Do not create a second list and attach it blindly — replacing the
> subnet's list detaches the existing egress rules.

---

## 2. Security headers

`backend/Caddyfile` is now the single source of truth for the edge config and is
deployed by the pipeline. It adds:

- `Content-Security-Policy` — `default-src 'self'`, scripts only from the
  Vite bundle, `object-src 'none'`, `base-uri 'self'`, `form-action 'self'`,
  `frame-ancestors 'none'`, `upgrade-insecure-requests`.
- `Permissions-Policy` — camera, microphone, geolocation, payment, USB and
  related features disabled.
- `Cross-Origin-Opener-Policy: same-origin` and
  `Cross-Origin-Resource-Policy: same-origin`.
- `X-XSS-Protection: 0` (the legacy auditor is removed from modern browsers and
  is itself a source of side channels).
- `-Server` so the reverse proxy no longer advertises itself.

`style-src` keeps `'unsafe-inline'` because the React components use inline
`style={{ ... }}` attributes. Removing it requires moving those styles into CSS
classes first; only then tighten the directive to `style-src 'self'`.

The deploy step runs `caddy validate` on a staged copy before replacing
`/etc/caddy/Caddyfile`, keeps the previous file as `Caddyfile.bak`, and reloads
Caddy. A broken header block can therefore not take the site down.

Verify after the deploy:

```bash
curl -sI https://oracle-infra.duckdns.org | grep -Ei 'content-security-policy|permissions-policy|strict-transport|x-frame|x-content-type|referrer'
```

---

## 3. Login rate limiting

`backend/main.go` now throttles `/api/login` per client IP:

- 5 failed attempts within a 60-second window → `429 Too Many Requests` with a
  `Retry-After` header until the window expires.
- A successful login clears that IP's counter.
- Malformed bodies count as failures.
- Username/password comparison uses SHA-256 digests before the constant-time
  compare, so response timing no longer leaks credential length.

`X-Forwarded-For` is only trusted when the direct peer is the loopback address
of the local Caddy proxy; the right-most entry (the value Caddy appends) is
used. A client that connects directly cannot spoof the header to bypass the
limiter, and the audit log records the real client address.

Limitations and follow-ups:

- The counters are in memory, per process. A restart clears them, and a
  distributed botnet can still spread attempts across many IPs. If that becomes
  a concern, move the limiter to a shared store (Redis) and add a global
  ceiling.
- The admin password and `SECOPS_JWT_SECRET` are now rendered on every deploy
  from repository secrets. The previous workflow contained a hard-coded
  fallback (`admin` / `oracle123!` / a fixed JWT key). **If that fallback was
  ever deployed, rotate both values now** — changing `SECOPS_JWT_SECRET`
  invalidates all existing sessions.
- Consider adding a second factor (TOTP) if the operator console is exposed to
  the public internet long-term.

Tests:

```bash
cd backend
go test ./...

# End-to-end runtime checks against a local instance (never production)
cd ..
SECOPS_SMOKE_AUTOSTART=1 bash scripts/security-smoke.sh
```

The unit tests cover the limiter window/lockout, the trusted-proxy logic, the
`429` response, and the request-body limit. The smoke suite re-verifies the same
behaviour over HTTP (CORS allowlist, unauthenticated and tampered-token
rejection, oversized bodies, per-IP lockout isolation) and runs as the
`backend-smoke` job in `security.yml`.
