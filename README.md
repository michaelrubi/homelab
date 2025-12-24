# 🚀 Rubiconetic Home Lab (Kubernetes / K3s)

![Status](https://img.shields.io/badge/Status-Production-success?style=for-the-badge)
![Kubernetes](https://img.shields.io/badge/kubernetes-%23326ce5.svg?style=for-the-badge&logo=kubernetes&logoColor=white)
![n8n](https://img.shields.io/badge/n8n-ff6584?style=for-the-badge&logo=n8n&logoColor=white)
![Postgres](https://img.shields.io/badge/postgres-%23316192.svg?style=for-the-badge&logo=postgresql&logoColor=white)
![Cloudflare](https://img.shields.io/badge/Cloudflare-F38020?style=for-the-badge&logo=Cloudflare&logoColor=white)

## 📖 Overview

This repository contains the Infrastructure-as-Code (IaC) manifests for my personal Kubernetes cluster ("Rubiconetic"). The goal of this project was to migrate from a PaaS-based workflow (Coolify) to a fully self-hosted, distributed Kubernetes cluster running on bare-metal mini PCs.

It serves as the production backend for my freelance automation business, hosting workflow engines, databases, and internal dashboards.

## 🏗️ Architecture

### Network Strategy: The "Hybrid Access" Model

I implemented a split-horizon network security model to balance client accessibility with internal security:

- **Public Access (Client-Facing):** Uses **Cloudflare Tunnels** to expose specific webhook endpoints (n8n) to the internet without opening ports on the firewall. This allows GitHub/Stripe webhooks to reach the cluster securely via SSL.
- **Private Access (Admin-Facing):** Uses **Tailscale** (Mesh VPN) for all administrative tools (CloudBeaver, Homepage, Longhorn). These services are completely invisible to the public internet and can only be accessed via authenticated devices.

### Storage & Persistence

- **Database:** Self-hosted PostgreSQL 16 running as a StatefulSet.
- **Storage Class:** **Longhorn** provides distributed block storage, ensuring data persists even if a specific node fails.
- **Disaster Recovery:** Automated pg_dump workflows back up data externally.

### Tech Stack

| Component             | Technology      | Reasoning                                                                |
| :-------------------- | :-------------- | :----------------------------------------------------------------------- |
| **Orchestrator**      | **K3s**         | Lightweight, production-grade Kubernetes perfect for edge hardware.      |
| **Ingress (Public)**  | **Cloudflared** | Zero-Trust tunneling; eliminates need for static IPs or port forwarding. |
| **Ingress (Private)** | **Tailscale**   | Secure, encrypted mesh network for internal tooling access.              |
| **Automation**        | **n8n**         | Self-hosted workflow automation engine.                                  |
| **Observability**     | **Homepage**    | Centralized dashboard for service health and cluster stats.              |

## 📂 Repository Structure

This repo follows a standard GitOps structure:

```txt
/manifests
  ├── automation/        # n8n deployments & services
  ├── infrastructure/    # Core networking (Cloudflared, Homepage)
  ├── database/          # Postgres StatefulSets & CloudBeaver
  └── secrets/           # (GitIgnored) Encrypted credentials
```

## Lessons Learned & Challenges

- **DNS Hairpinning:** Encountered issues where internal services could not ping each other via their external Tailscale IPs. Resolved by implementing internal Kubernetes FQDNs (`svc.cluster.local`) for direct service-to-service communication.
  - **Migration Strategy:** successfully migrated a live production database from Coolify to K3s by managing encryption key continuity and performing a clean `pg_dump`/`psql` restore process.
- **Read-Only ConfigMaps:** Overcame application crashes in `Homepage` caused by read-only volume mounts by implementing correct config initialization strategies.

## 🚀 Future Roadmap

- \[ \] Implement **Sealed Secrets** to allow safe committing of encrypted secrets to Git.
- \[ \] Add historical metrics monitoring.
- \[ \] Automate OS patching.

---

Built & Maintained by Michael Rubi
