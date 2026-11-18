# Oracle Cloud (OCI) DevOps Infrastructure

[![Enterprise DevOps CI/CD Pipeline](https://github.com/ongunakaycom/oracle-infra/actions/workflows/deploy.yml/badge.svg)](https://github.com/ongunakaycom/oracle-infra/actions/workflows/deploy.yml)
[![IaC Security: Trivy + KICS + OPA](https://img.shields.io/badge/Security-Trivy%20%2B%20KICS%20%2B%20OPA-brightgreen?logo=opensourceinitiative&logoColor=white)](.github/workflows/security.yml)
[![Terraform Version](https://img.shields.io/badge/Terraform-%3E%3D1.10.0-623CE4?logo=terraform&logoColor=white)](https://www.terraform.io)
[![Go Version](https://img.shields.io/badge/Go-1.23-00ADD8?logo=go&logoColor=white)](https://golang.org)
[![React Version](https://img.shields.io/badge/React-19-61DAFB?logo=react&logoColor=black)](https://react.dev)
[![Vite Version](https://img.shields.io/badge/Vite-8-646CFF?logo=vite&logoColor=white)](https://vite.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Production-oriented infrastructure-as-code and CI/CD setup for a **React + Vite** frontend and **Go (SQLite)** backend hosted on an **Oracle Cloud Infrastructure Always Free** compute instance, protected by OCI Bastion, Caddy edge security headers, and automated vulnerability scanning.

**Live URL:** https://oracle-infra.duckdns.org/ *(DNS via DuckDNS)*

Terraform provisions and protects the OCI resources, GitHub Actions validates the infrastructure and deploys every frontend build to the server over SSH/rsync.

---

## Architecture

```
 Developer                 GitHub                        OCI (Always Free)
 ─────────                 ──────                        ─────────────────
 git push  ──────────────► Actions workflow
                              │
                              ├─► terraform fmt / init / validate
                              ├─► Trivy + KICS IaC scans
                              ├─► OPA/Rego Always Free policy gate
                              ├─► hardened build + CycloneDX SBOMs
                              └─► cosign sign-blob (keyless OIDC)
                                        │
                                        └── signed release bundle ──► VM.Standard.E2.1.Micro
                                                                      ├─ cosign verify-blob (fail = no deploy)
                                                                      └─ Caddy (TLS + security headers)
                                                                         web root: /usr/share/nginx/html

 Terraform state ──► OCI Object Storage (S3-compatible backend, native lockfile)
```

| Layer | Technology |
| --- | --- |
| Infrastructure | Terraform `>= 1.10.0`, OCI provider `~> 6.0` |
| Compute | `VM.Standard.E2.1.Micro` (Always Free), public IP |
| Network | VCN subnet + Network Security Group `nsg-enterprise-web-prod` |
| Remote state | OCI Object Storage via S3-compatible backend with `use_lockfile = true` |
| DNS / Demo URL | DuckDNS — `https://oracle-infra.duckdns.org/` (maps to instance IP) |
| Admin access | OCI Bastion Service (no public SSH) |
| Frontend | React 19 + Vite 8 + ESLint 10 |
| CI/CD | GitHub Actions (validate, security scan, build, rsync deploy) |

---

## Repository layout

| Path | Purpose |
| --- | --- |
| `provider.tf` | Terraform/OCI provider configuration and S3-compatible remote backend |
| `variables.tf` | Input variables for OCI identifiers, network and access control |
| `instance.tf` | Always Free compute instance with `prevent_destroy` and `ignore_changes` guards |
| `security.tf` | NSG, ingress rules for HTTP/HTTPS/internal SSH, and a plan-time check for public SSH in Security Lists |
| `bastion.tf` | OCI Bastion Service used for administrative tunneling |
| `budget.tf` | `oci_budget_budget` + alert rules that fire on any non-free spend |
| `policies/oci_free_tier.rego` | OPA/Rego gate enforcing the OCI Always Free limits in CI |
| `policies/testdata/bad/` | Negative fixtures: the gate must reject these (CI self-test) |
| `backend/` | Go SecOps API (JWT auth, audit log, login rate limiting) and its `Caddyfile` edge config |
| `docs/security-remediation.md` | Runbook for the DAST/network audit findings (SSH, headers, rate limiting) |
| `outputs.tf` | Public and private IP outputs |
| `terraform.tfvars.example` | Template for the required variable values |
| `.github/workflows/deploy.yml` | CI/CD pipeline |
| `frontend/` | React + Vite application that is built and deployed |

> The `.tf`, `.py` and `index.html` files in the repository root are part of the infrastructure layer; the deployed website is built from `frontend/`.

---

## Infrastructure

### Compute instance

- Shape: `VM.Standard.E2.1.Micro` (1 OCPU / 1 GB) — Always Free eligible.
- Public IP is assigned; the instance is attached to NSG `nsg-enterprise-web-prod`.
- `lifecycle.prevent_destroy = true` prevents accidental destruction.
- `ignore_changes` is set for image, metadata, and tags so that image updates, SSH key
  changes and console edits never force a recreate.

### Network security (`security.tf`)

| Direction | Protocol | Port | Source | Purpose |
| --- | --- | --- | --- | --- |
| INGRESS | TCP | 80 | `0.0.0.0/0` | HTTP (redirect + ACME challenges) |
| INGRESS | TCP | 443 | `0.0.0.0/0` | HTTPS |
| INGRESS | TCP | 22 | `10.0.0.0/16` (VCN) | SSH, reachable only through the bastion |

Public SSH is intentionally not exposed.

> NSG rules are **additive** with the subnet's Security Lists: a Security List
> rule allowing `0.0.0.0/0 → 22` re-opens SSH no matter what the NSG says.
> `terraform plan` now prints a warning when such a rule is attached to the
> subnet; see `docs/security-remediation.md` for the removal procedure.

### Bastion (`bastion.tf`)

A `STANDARD` OCI Bastion is attached to the target subnet. Which client networks may
connect is controlled by `bastion_allowed_cidrs`. The default is the operator's current
egress IP (`83.52.157.115/32`); update it whenever that IP changes, and never widen it to
`0.0.0.0/0` in production.

### Remote state

State lives in the OCI Object Storage bucket configured in `provider.tf`:

- Key: `prod/terraform.tfstate`
- S3-compatible endpoint (`*.compat.objectstorage.<region>.oraclecloud.com`)
- Path-style addressing, checksum and credential validation disabled for compatibility
- Native state locking via `use_lockfile = true` (Terraform 1.10+)

Never commit `*.tfstate`, `*.tfvars` or private keys. They are already covered by `.gitignore`.

---

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) `>= 1.10.0`
- OCI tenancy with an API key pair (`~/.oci/oci_api_key.pem`)
- OCI identifiers: tenancy OCID, user OCID, API key fingerprint, compartment OCID,
  availability domain, subnet OCID, VCN OCID
- Node.js 20+ and npm (for the frontend)

---

## Local setup

Internal use only — clone locally as usual, then:

```bash
# 1. Provide variables
cp terraform.tfvars.example terraform.tfvars
#    then fill in the OCIDs and paths

# 2. Initialise providers and remote state
terraform init

# 3. Review the plan
terraform plan

# 4. Apply (only when the plan is expected)
terraform apply
```

### Required variables

| Variable | Required | Description |
| --- | --- | --- |
| `tenancy_ocid` | yes | OCI tenancy OCID |
| `user_ocid` | yes | OCI user OCID owning the API key |
| `fingerprint` | yes | API key fingerprint |
| `private_key_path` | no | API private key path (default `~/.oci/oci_api_key.pem`) |
| `region` | no | OCI region (default `eu-frankfurt-1`) |
| `compartment_id` | yes | Compartment OCID for all resources |
| `availability_domain` | no | Target AD (default `FVLm:EU-FRANKFURT-1-AD-3`) |
| `subnet_id` | yes | Subnet the instance and bastion attach to |
| `vcn_id` | yes | VCN owning the NSG |
| `ssh_public_key` | no | Public key injected into instance metadata |
| `bastion_allowed_cidrs` | no | CIDRs allowed to use the bastion |
| `budget_alert_emails` | no | Recipients for budget alerts; empty list disables the budget |
| `budget_amount_usd` | no | Monthly budget ceiling in USD (default `1`) |

### Outputs

```bash
terraform output instance_public_ip
terraform output instance_private_ip
```

---

## Frontend

```bash
cd frontend
npm ci          # clean install
npm run dev     # local dev server with HMR
npm run lint    # ESLint
npm run build   # production build -> frontend/dist
npm run preview # preview the production build locally
```

The build output (`frontend/dist`) is what the pipeline uploads to the server.
It is generated, not committed.

---

## CI/CD pipeline

`.github/workflows/deploy.yml` and `.github/workflows/security.yml` run on every
push and pull request to `main`/`master`.

**Job 1 — Terraform validate & security scan** (all events)

1. `terraform fmt -check`
2. `terraform init -backend=false`
3. `terraform validate`
4. Checkov Terraform scan (`soft_fail: true`, findings are reported but do not block)

**Job 2 — Terraform security & Always Free guard** (`security.yml`, all events)

1. **Trivy** `config` scan of the Terraform root (successor of tfsec, which
   received its last rule updates before being merged into Trivy); fails on
   `HIGH`/`CRITICAL`.
2. **KICS** Terraform scan as an independent second engine (Terrascan was
   archived in November 2025); fails on high/critical findings.
3. **Conftest/OPA** evaluates `policies/oci_free_tier.rego` against the HCL
   files directly (`--combine --parser hcl2`, no OCI credentials needed):
   paid shapes, more than 2 × `E2.1.Micro`, more than 4 OCPU / 24 GB total on
   A1.Flex, more than 200 GB of block storage, and a bastion open to the
   internet all fail the job. Infracost cannot price OCI resources, so this
   policy gate is what protects the free tier — together with the
   `oci_budget_budget` alert defined in `budget.tf`.
4. A self-test runs the same policy against `policies/testdata/bad/` and fails
   the job if the violations there are not reported, so the gate cannot
   silently degrade into a no-op.

Run the free-tier gate locally before pushing:

```bash
conftest test --combine --parser hcl2 --policy policies $(find . -maxdepth 1 -name '*.tf')
```

**Job 3 — Build, attest & deploy (Layer 4)** (push to `main`/`master` only)

1. Checkout, Node.js 20 with npm cache (`frontend/package-lock.json`)
2. `npm ci && npm run build` in `frontend/`
3. Frontend SBOM: `@cyclonedx/cyclonedx-npm --omit dev` → `sbom-frontend.json`
4. Go 1.26.11; `go vet` + `go test -race`, then a hardened build:
   `CGO_ENABLED=0 -trimpath -ldflags="-s -w -buildid="`
5. Backend SBOM: `cyclonedx-gomod mod` → `sbom-backend.json`
6. Assemble `release-bundle.tar.gz` (frontend dist, API binary, systemd unit, Caddyfile)
   plus its `sha256` checksum
7. Keyless signing with Cosign (Sigstore OIDC, `id-token: write`):
   `cosign sign-blob --bundle release-bundle.tar.gz.sigstore.json`
8. Upload the SBOMs and the signature as the `layer4-release-evidence` Actions artifact
9. Transfer the bundle, checksum and Sigstore bundle to `~/releases` on the host
10. **On the server, before anything is installed:** `sha256sum -c`, then
    `cosign verify-blob` pinned to this workflow identity
    (`…/deploy.yml@refs/heads/main`) and to the GitHub OIDC issuer. A failed
    verification aborts the deploy, so unsigned or tampered artifacts never reach
    production.
11. Render `/etc/secops/secops.env` (mode `600`, root-owned) from repository secrets only —
    no credential is ever stored in the repository and the deploy fails fast if a secret is
    missing
12. Extract the verified bundle, install the binary in `/opt/secops` (outside `/home`, so
    systemd may execute it under SELinux), publish the frontend and refresh contexts with
    `restorecon`
13. Validate the new Caddyfile with `caddy validate`, back up the previous one and reload the
    edge proxy
14. `systemctl daemon-reload && systemctl restart secops-api`
15. Verify the deployment: print `systemctl status` and the last journal lines, then probe
    `http://127.0.0.1:8080/api/health`. **The job fails if the service does not answer**, so
    a broken release can no longer hide behind a `502` from the reverse proxy.

### Required GitHub configuration

| Name | Type | Purpose |
| --- | --- | --- |
| `SSH_PRIVATE_KEY` | Repository secret | Private key for the `opc` user on the target instance |
| `SECOPS_ADMIN_USER` | Repository secret | Operator username loaded into `/etc/secops/secops.env` |
| `SECOPS_ADMIN_PASS` | Repository secret | Operator password loaded into `/etc/secops/secops.env` |
| `SECOPS_JWT_SECRET` | Repository secret | HMAC key used to sign and verify HS256 tokens |
| `REMOTE_HOST` | Repository variable | Deploy target address (`89.168.99.211`) |

The deploy host is read from the `REMOTE_HOST` repository variable, so an IP change only
requires updating the variable — no code change. The job fails fast with an explicit error
if any of the values above is empty.

Set it from the CLI:

```bash
echo "oracle-infra.duckdns.org" | gh variable set REMOTE_HOST
gh variable get REMOTE_HOST   # verify
```

---

## Security posture

- No secrets, private keys, state files or `*.tfvars` in version control.
- Public SSH is not exposed; administration goes through OCI Bastion. The plan
  warns if a subnet Security List re-opens port 22 to the internet.
- Security headers (HSTS, CSP, Permissions-Policy, `X-Frame-Options: DENY`,
  `nosniff`, COOP/CORP) are defined in `backend/Caddyfile` and applied by the
  deployed edge proxy.
- `/api/login` throttles failed attempts per client IP (5 per 15 minutes,
  `429` + `Retry-After`) and compares credential digests in constant time.
- The instance is protected against accidental destroy/recreate.
- The pipeline receives only a deploy key, not OCI API credentials, so a compromised
  workflow cannot modify infrastructure.
- Checkov runs on every change (`soft_fail: true`); Trivy, KICS and the OPA
  free-tier gate run as hard gates in the Layer 3 job.
- Dependabot keeps GitHub Actions, npm and Go modules patched (supply-chain
  integrity for the pipeline itself).
- Layer 4: the release bundle is built from a hardened Go binary
  (`-trimpath`, stripped, empty build ID), accompanied by CycloneDX SBOMs and
  signed keylessly with Cosign. The server verifies checksum **and** signature
  against this workflow's OIDC identity before installing anything, so a
  compromised runner without OIDC cannot push an unsigned binary.
- Commits are SSH-signed (ED25519) and changes reach `main` only through a
  pull request that passes the security workflows.

See [`docs/security-remediation.md`](docs/security-remediation.md) for the audit
findings, live-tenant runbook and verification commands.

---

## Known gaps / next steps

- [x] ~~The deploy host is hardcoded in the workflow~~ — now read from `vars.REMOTE_HOST`.
- [x] ~~`bastion_allowed_cidrs` defaults to `0.0.0.0/0`; set it to trusted ranges.~~ — restricted to operator egress IP (`83.52.157.115/32`).
- [x] ~~`frontend/dist` is not ignored by Git; add it to `.gitignore`.~~ — added.
- [x] ~~`.gitignore` contains a stray `Y` line and ignores all `*.py` files, which also hides the helper scripts.~~ — cleaned.
- [x] ~~Legacy helpers (`add_key.py`, `extract_key.py`, `fix_and_connect.py`, `update_infra.py`) and the repository-root `index.html` are unused by the pipeline and can be removed.~~ — removed.

---

## Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| `terraform init` fails on the backend | Wrong bucket, endpoint or region in `provider.tf`; check OCI customer secret keys and bucket name |
| `terraform apply` refuses to replace the instance | Expected: `prevent_destroy` is enabled. Change the lifecycle block intentionally if a recreate is truly required |
| Deploy step fails on `rsync` | Missing `SSH_PRIVATE_KEY`, `REMOTE_HOST` variable unset/wrong, or the key is not authorised for `opc` |
| Website shows old content after deploy | `rsync --delete` runs on `/usr/share/nginx/html`; confirm the workflow completed and Caddy serves that root |
| SSH from your machine times out | Port 22 is only open from the VCN CIDR; connect through the OCI Bastion session instead |

---

## License

[MIT](LICENSE) © Ongun Akay