# Enterprise Oracle Cloud (OCI) DevOps & CI/CD Infrastructure

This repository contains a production-grade, enterprise-level DevOps architecture deployed on **Oracle Cloud Infrastructure (OCI)** utilizing **Terraform**, **Caddy** (with automatic Let's Encrypt SSL), and **GitHub Actions** for CI/CD automation.

---

## 🌟 Architecture Overview

```
[Developer (Git Push)] 
       │
       ▼
[GitHub Actions CI/CD] ──(Security Scan / Build / Deploy)──► [OCI VM (Always Free)]
       │                                                         │
       ├─► Terraform (State on OCI Object Storage)               └─► Caddy (HTTP/HTTPS & SSL)
       └─► Security Linting (Checkov)
```

---

## 🔒 1. Security & Compliance (Zero Trust)
* **Secret Management & Repo Hygiene:** Sensitive files, API keys (`.pem`), and local state files (`.tfstate`) are excluded via `.gitignore` and managed securely through **GitHub Actions Secrets**.
* **Remote State & Locking:** Terraform state is stored securely in an encrypted **OCI Object Storage Bucket**, utilizing native state locking (`use_lockfile = true`) to prevent race conditions during concurrent runs.
* **Network Security Group (NSG):** Direct public access via SSH (`Port 22`) is disabled. Web traffic is strictly restricted to HTTP (`80`) and HTTPS (`443`), protected by dedicated OCI NSGs.
* **Always Free Protection:** Configured with `prevent_destroy = true` and comprehensive `ignore_changes` blocks to safeguard the `VM.Standard.E2.1.Micro` instance against accidental recreation or destruction.

---

## 🏗️ 2. Infrastructure as Code (Terraform Structure)

The codebase is organized into modular, clean components:
* `provider.tf`: OCI provider configuration and S3-compatible remote backend.
* `variables.tf`: Parametrized variables for environments and resource OCIDs.
* `instance.tf`: Always Free compute instance configuration with lifecycle protection.
* `security.tf`: Zero-Trust Network Security Group (NSG) and firewall rules.
* `bastion.tf`: OCI Bastion Service integration for secure administrative tunneling.
* `outputs.tf`: Public/private IP outputs.

---

## 🚀 3. CI/CD Pipeline (GitHub Actions)

Every push to `main` triggers a fully automated enterprise pipeline:
1. **Lint & Validate:** `terraform fmt` and `terraform validate` check syntax.
2. **Security Scan:** `Checkov` scans infrastructure code for security misconfigurations.
3. **Build & Deploy:** Automated compilation and deployment of web assets directly to the production OCI server.

---

## 🌐 4. Web Server & SSL
* **Caddy Web Server:** Lightweight, high-performance web server replacing traditional Nginx.
* **Automated SSL:** Seamless integration with **Let's Encrypt** via dynamic DNS (`nip.io`), providing valid HTTPS encryption out-of-the-box.

---

## 🛠️ Quick Start

1. **Clone the repository:**
   ```bash
   git clone https://github.com/ongunakaycom/oracle-infra.git
   cd oracle-infra
   ```

2. **Initialize Terraform:**
   ```bash
   terraform init
   ```

3. **Plan infrastructure changes:**
   ```bash
   terraform plan
   ```
