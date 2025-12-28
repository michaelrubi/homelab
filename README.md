# 🚀 Rubiconetic Home Lab (Kubernetes / K3s)

![Status](https://img.shields.io/badge/Status-Production-success?style=for-the-badge)
![Kubernetes](https://img.shields.io/badge/kubernetes-%23326ce5.svg?style=for-the-badge&logo=kubernetes&logoColor=white)
![Flux](https://img.shields.io/badge/Flux-GitOps-2f618b?style=for-the-badge&logo=flux&logoColor=white)
![n8n](https://img.shields.io/badge/n8n-ff6584?style=for-the-badge&logo=n8n&logoColor=white)
![Postgres](https://img.shields.io/badge/postgres-%23316192.svg?style=for-the-badge&logo=postgresql&logoColor=white)
## 📖 Overview
This repository contains the **GitOps** Infrastructure-as-Code (IaC) manifests for my personal Kubernetes cluster ("Rubiconetic").
It serves as the production backend for my freelance automation business, hosting workflow engines, databases, and internal dashboards. The entire cluster state is reconciled automatically from this repository using **FluxCD**.
## 🏗️ Architecture
### Network Strategy: The "Hybrid Access" Model
I implemented a split-horizon network security model to balance client accessibility with internal security:
- **Public Access (Client-Facing):** Uses **Cloudflare Tunnels** to expose specific webhook endpoints (n8n) to the internet without opening ports on the firewall.
- **Private Access (Admin-Facing):** Uses **Tailscale** (Mesh VPN) for all administrative tools (Pgweb, Homepage, Longhorn). These services are completely invisible to the public internet.
### GitOps & Automation
- **Synchronization:** **FluxCD** watches this repository and automatically applies changes to the cluster within 1 minute.
- **Secret Management:** Secrets are encrypted locally using **SOPS (Secrets OPerationS)** and **Age**, allowing credentials to be safely committed to the public repository.
- **Auto-Restarts:** **Stakater Reloader** watches for secret changes and automatically restarts deployments to apply new credentials.
### Tech Stack

| Component | Technology  | Reasoning   |
| :-------------------- | :-------------- | :------------------------------------------------------------------ |
| **Orchestrator**  | **K3s** | Lightweight, production-grade Kubernetes perfect for edge hardware. |
| **GitOps Engine** | **FluxCD**  | Automated reconciliation; "Git is the single source of truth."  |
| **Secret Encryption** | **SOPS + Age**  | Client-side encryption allowing safe storage of secrets in Git. |
| **Ingress (Public)**  | **Cloudflared** | Zero-Trust tunneling; eliminates need for static IPs.   |
| **Ingress (Private)** | **Tailscale**   | Secure, encrypted mesh network for internal tooling access. |
| **Storage**   | **Longhorn**| Distributed block storage for high availability.|
| **Observability** | **Homepage**| Centralized dashboard for service health and cluster stats. |
## 📂 Repository Structure
This repo follows a standard Flux v2 GitOps structure:
```txt
/clusters
  └── my-cluster/# Flux Kustomization definitions & Sync config
/manifests
  ├── automation/# n8n & Postgres deployments
  ├── infrastructure/# Core networking (Cloudflared, Homepage) & Tools (Reloader)
  ├── productivity/  # SiYuan & other apps
  └── secrets/   # SOPS-encrypted Kubernetes Secrets
```
## Lessons Learned & Challenges
- **The GitOps Transition:** Migrated from manual `kubectl apply` workflows to Flux. Learned to manage "Secret Zero" using SOPS and how to debug Kustomize reconciliation failures when encrypted metadata is malformed.
- **DNS Hairpinning:** Resolved internal service communication issues by enforcing Kubernetes internal FQDNs (`svc.cluster.local`) instead of relying on external Tailscale IPs for pod-to-pod talk.
- **Database Migration:** Successfully migrated a live production database from Coolify to K3s by managing encryption key continuity and performing a clean `pg_dump`/`psql` restore process.
## 🚀 Future Roadmap
- [x] Implement **GitOps (Flux + SOPS)** to allow safe committing of encrypted secrets to Git.
- [x] Configure **Renovate** for automated Docker image updates.
- [x] Add historical metrics monitoring (Prometheus/Grafana).
- [X] **Cluster Hardening**: Add Liveness/Readiness probes and Resource Limits to all deployments.
- [ ] **Disaster Recovery**: Configure Longhorn S3 backups.
- [ ] **Database Consolidation**: Migrate VaultWarden from SQLite to Postgres.
- [ ] **Observability**: Set up Flux Notifications (Discord/Slack).
- [ ] **New Apps**: Deploy **ntfy** for push notifications.
---
Built & Maintained by Michael Rubi