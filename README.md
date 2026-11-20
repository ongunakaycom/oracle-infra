# Oracle Cloud (OCI) DevOps Infrastructure

[![Enterprise DevOps CI/CD Pipeline](https://github.com/ongunakaycom/oracle-infra/actions/workflows/deploy.yml/badge.svg)](https://github.com/ongunakaycom/oracle-infra/actions/workflows/deploy.yml)
[![DevSecOps Security Scan](https://github.com/ongunakaycom/oracle-infra/actions/workflows/security.yml/badge.svg)](https://github.com/ongunakaycom/oracle-infra/actions/workflows/security.yml)
[![IaC Security: Trivy + KICS + OPA](https://img.shields.io/badge/IaC-Trivy%20%2B%20KICS%20%2B%20OPA-brightgreen)](.github/workflows/security.yml)
[![Supply chain: SBOM + Cosign](https://img.shields.io/badge/Supply%20chain-CycloneDX%20%2B%20Cosign-blueviolet)](.github/workflows/deploy.yml)
[![Terraform Version](https://img.shields.io/badge/Terraform-%3E%3D1.10.0-623CE4?logo=terraform&logoColor=white)](https://www.terraform.io)
[![Go Version](https://img.shields.io/badge/Go-1.26.11-00ADD8?logo=go&logoColor=white)](https://golang.org)
[![React Version](https://img.shields.io/badge/React-19-61DAFB?logo=react&logoColor=black)](https://react.dev)
[![Vite Version](https://img.shields.io/badge/Vite-8-646CFF?logo=vite&logoColor=white)](https://vite.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Production-oriented infrastructure-as-code and CI/CD setup for a **React + Vite** frontend and **Go (SQLite)** backend hosted on an **Oracle Cloud Infrastructure Always Free** compute instance, protected by OCI Bastion, Caddy edge security headers, and a signed, SBOM-backed release pipeline.

**Live URL:** https://oracle-infra.duckdns.org/ *(DNS via DuckDNS)*

Terraform provisions and protects the OCI resources; GitHub Actions validates the infrastructure, builds a hardened artifact, signs it keylessly with Sigstore, and only then deploys the verified bundle to the server over SSH.

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
| IaC security | Trivy `config` + Checkmarx KICS + OPA/Rego Always Free gate (Conftest) |
| Supply chain | CycloneDX SBOMs, keyless Cosign (`sign-blob`/`verify-blob`), Dependabot |
| Runtime | Go 1.26.11 (hardened build), systemd, Caddy, SQLite |
| CI/CD | GitHub Actions (validate, scan, build, sign, verify, deploy) |

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
| `.github/workflows/deploy.yml` | Validate + build, SBOM, sign, verify and deploy (Layer 4) |
| `.github/workflows/security.yml` | Secrets, dependency, IaC and Always Free gates (Layers 1–3) |
| `.github/dependabot.yml` | Weekly updates for Actions, npm and Go modules |
| `frontend/` | React + Vite application that is built and deployed |

> The deployed website is built from `frontend/`; the Terraform root files are the
> infrastructure layer. Generated evidence (`sbom-*.json`, `release/`,
> `release-bundle.tar.gz*`) is ignored by Git and lives only in CI artifacts.

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
egress IP (`89.168.99.211/32`); update it whenever that IP changes, and never widen it to
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
- Go 1.26.11 (for the backend)

Optional, for reproducing the CI gates locally:

- [Conftest](https://www.conftest.dev/install/) (OPA/Rego policy gate)
- [Trivy](https://trivy.dev/latest/getting-started/installation/) (`trivy config .`)
- [Cosign](https://docs.sigstore.dev/cosign/system_config/installation/) (signature
  verification, same major version as the server)

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

### Local security checks

Run the same gates as CI before opening a PR:

```bash
terraform fmt -check
terraform validate

# OCI Always Free policy gate (no cloud credentials required)
conftest test --combine --parser hcl2 --policy policies $(find . -maxdepth 1 -name '*.tf')

# IaC scan (Trivy picks the Terraform files up from the repository root)
trivy config --severity HIGH,CRITICAL --exit-code 1 .
```

The API's runtime behaviour is covered by `scripts/security-smoke.sh`. It
refuses non-loopback targets by design, so it can never fuzz production:

```bash
# build backend/, start it on 127.0.0.1:8080 with a throwaway key, then test
SECOPS_SMOKE_AUTOSTART=1 bash scripts/security-smoke.sh

# or point it at an already running local instance
BASE_URL=http://127.0.0.1:8080 bash scripts/security-smoke.sh
```

It verifies the security headers/CORS allowlist, unauthenticated and
tampered-token rejection, login, `/api/records` validation, the 5-failed-attempt
lockout with `Retry-After`, per-IP lockout isolation and the 4 KB/8 KB body
limits. The same suite runs as the `backend-smoke` job in `security.yml`;
production is only ever health-checked and TLS-scanned read-only.

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

# Same SBOM CI publishes, limited to production dependencies
npx --yes @cyclonedx/cyclonedx-npm@7.0.1 --omit dev --output-file ../sbom-frontend.json
```

`frontend/dist` is generated at build time and packaged into the signed release
bundle; it is never committed.

---

## CI/CD pipeline

Two workflows run on every push and pull request to `main`/`master`; the deploy
job itself only runs on pushes.

### `security.yml` — Layers 1–3 and runtime smoke

**`security-audit` (Layer 1 & 2)**

1. Gitleaks secret scan (primary, uses `GITHUB_TOKEN`)
2. TruffleHog verified-secret scan (secondary)
3. Frontend ESLint
4. `npm audit --omit=dev --audit-level=high` as a hard gate (full tree reported)
5. `govulncheck` on Go 1.26.11
6. Snyk deep dependency scan (skipped when `SNYK_TOKEN` is not configured)
7. `bash -n` + ShellCheck for the DR scripts

**`terraform-security` (Layer 3)**

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
   the job if the violations there are not reported (Conftest colours its
   output, hence `--no-color`), so the gate cannot silently become a no-op.

**`backend-smoke` (runtime)**

1. Builds `backend/` with Go 1.26.11 and starts it on `127.0.0.1:8080` using a
   randomly generated JWT key and a temporary SQLite file.
2. Runs `scripts/security-smoke.sh`, which rejects any non-loopback target, so
   the negative traffic (failed logins, oversized bodies) never reaches the
   production Always Free instance.

Run the free-tier gate locally before pushing:

```bash
conftest test --no-color --combine --parser hcl2 --policy policies $(find . -maxdepth 1 -name '*.tf')
```

### `deploy.yml` — Terraform validation & Layer 4

**`terraform-validate-and-security`** (all events)

1. `terraform fmt -check`
2. `terraform init -backend=false`
3. `terraform validate`
4. Checkov Terraform scan (`soft_fail: true`, findings are reported but do not block)

**`deploy-static-content`** (push to `main`/`master` only)

1. Checkout, Node.js 20 with npm cache (`frontend/package-lock.json`)
2. `npm ci && npm run build` in `frontend/`
3. Frontend SBOM: `@cyclonedx/cyclonedx-npm@7.0.1 --omit dev` → `sbom-frontend.json`
4. Go 1.26.11; `go vet` + `go test -race`, then a hardened build:
   `CGO_ENABLED=0 -trimpath -ldflags="-s -w -buildid="`
5. Backend SBOM: `cyclonedx-gomod@v1.12.0 mod` → `sbom-backend.json`
6. Assemble `release-bundle.tar.gz` (frontend dist, API binary, systemd unit, Caddyfile)
   plus its `sha256` checksum
7. Keyless signing with Cosign v2.4.3 (Sigstore OIDC, `id-token: write`):
   `cosign sign-blob --bundle release-bundle.tar.gz.sigstore.json`
8. Upload the SBOMs, bundle and signature as the `layer4-release-evidence` artifact
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

#### Release evidence and manual verification

Every successful deploy leaves a `layer4-release-evidence` artifact (30-day
retention) containing both SBOMs, the release bundle, its checksum and the
Sigstore bundle. Verify a downloaded artifact exactly like the server does:

```bash
gh run download --name layer4-release-evidence --dir evidence
cd evidence

sha256sum -c release-bundle.tar.gz.sha256

cosign verify-blob \
  --bundle release-bundle.tar.gz.sigstore.json \
  --certificate-identity "https://github.com/ongunakaycom/oracle-infra/.github/workflows/deploy.yml@refs/heads/main" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  release-bundle.tar.gz
# => Verified OK
```

The OCI host installs `cosign` v2.4.3 on first use and performs the same check
before touching `/opt/secops` or `/usr/share/nginx/html`.

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

The deploy job also requests `id-token: write`: it exchanges that short-lived OIDC token for
a Sigstore certificate when signing the release bundle. No long-lived signing key is stored
in the repository — GitHub's OIDC provider must simply be available to Actions (the default
when Actions is enabled).

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
- `/api/login` throttles failed attempts per client IP (5 per 60-second
  window, `429` + `Retry-After`) and compares credential digests in constant
  time.
- The instance is protected against accidental destroy/recreate.
- The pipeline receives a deploy key and a short-lived OIDC token, but no OCI API
  credentials, so a compromised workflow cannot modify infrastructure.
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
- [x] ~~`bastion_allowed_cidrs` defaults to `0.0.0.0/0`; set it to trusted ranges.~~ — restricted to operator egress IP (`89.168.99.211/32`).
- [x] ~~`frontend/dist` is not ignored by Git; add it to `.gitignore`.~~ — added.
- [x] ~~`.gitignore` contains a stray `Y` line and ignores all `*.py` files, which also hides the helper scripts.~~ — cleaned.
- [x] ~~Legacy helpers (`add_key.py`, `extract_key.py`, `fix_and_connect.py`, `update_infra.py`) and the repository-root `index.html` are unused by the pipeline and can be removed.~~ — removed.
- [x] ~~tfsec / Terrascan / Infracost were part of the planned Layer 3 stack.~~ — replaced by Trivy + KICS + an OPA Always Free gate.
- [x] ~~Deployments trusted whatever the runner produced.~~ — the server now verifies a Cosign-signed, checksummed bundle before installing.
- [ ] Node.js 20 is deprecated on GitHub runners (annotation only). Plan the jump to
      Node 22/24 for `setup-node` and `@cyclonedx/cyclonedx-npm`.
- [ ] Dependabot opened major-upgrade PRs (`actions/checkout@v7`,
      `actions/setup-go@v6`); review and merge once the pinned Cosign/KICS
      versions are re-checked.

---

## Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| `terraform init` fails on the backend | Wrong bucket, endpoint or region in `provider.tf`; check OCI customer secret keys and bucket name |
| `terraform apply` refuses to replace the instance | Expected: `prevent_destroy` is enabled. Change the lifecycle block intentionally if a recreate is truly required |
| Deploy step fails on `rsync` | Missing `SSH_PRIVATE_KEY`, `REMOTE_HOST` variable unset/wrong, or the key is not authorised for `opc` |
| Deploy fails with `cosign: Error: verifying blob` | The bundle identity/issuer must match this workflow and branch; re-run the workflow from `main`. Nothing was installed — the previous release keeps serving |
| Deploy fails while installing `cosign` on the host | The instance cannot reach `github.com`; pre-install `cosign` v2.4.3 in `/usr/local/bin` or allow outbound HTTPS |
| `cyclonedx-gomod` / SBOM step fails | Go toolchain is older than `go.mod` (`1.26.11`) or the module cache is cold; re-run the job |
| `conftest` self-test reports "violations were not reported" | A policy edit removed the `input[].contents` unwrapping or the `deny` rules; run the local gate command above |
| Website shows old content after deploy | `rsync --delete` runs on `/usr/share/nginx/html`; confirm the workflow completed and Caddy serves that root |
| SSH from your machine times out | Port 22 is only open from the VCN CIDR; connect through the OCI Bastion session instead |

---

## License

[MIT](LICENSE) © Ongun Akay