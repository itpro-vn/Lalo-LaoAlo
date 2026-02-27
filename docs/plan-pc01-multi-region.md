# PC-01: Multi-Region Deployment — Implementation Plan

| Field        | Value              |
| ------------ | ------------------ |
| **ID**       | PC-01              |
| **Priority** | P0                 |
| **Estimate** | XL (2–4 weeks)     |
| **Deps**     | Phase B complete ✓ |
| **Owner**    | DevOps + Backend   |
| **Created**  | 2026-02-26         |
| **Status**   | Planning           |

---

## Overview

Deploy hệ thống ra 2 regions (Vietnam + Singapore) với GeoDNS routing, per-region Kubernetes clusters, cross-region data replication, và region failover.

### Current State

- Local dev only: `docker-compose.yml` + `Makefile`
- CI: GitHub Actions (lint, test, build)
- **Missing**: K8s manifests, IaC (Terraform), Helm charts, service Dockerfiles, production configs

### Target State

- 2 K8s clusters (Vietnam, Singapore), multi-AZ
- Full stack per region: signaling, orchestrator, policy, coturn, LiveKit
- Shared Postgres (primary VN, read replica SG)
- Per-region Redis cluster, NATS cluster
- GeoDNS → nearest region
- Health-based failover

---

## Sub-Tasks

### Wave 0 — Foundation (No dependencies)

#### PC-01.1: Service Dockerfiles

**Estimate**: S (1 day)
**Files to create**:

- `deployments/signaling/Dockerfile`
- `deployments/orchestrator/Dockerfile`
- `deployments/policy/Dockerfile`
- `deployments/push/Dockerfile`

**Details**:

- Multi-stage Go builds (build stage + alpine runtime)
- Non-root user, health check endpoint exposed
- Match existing `Makefile` references (`docker-build` target)
- Include migration binaries where needed

**Acceptance**:

- [ ] `docker build` succeeds for all 4 services
- [ ] Images are < 50MB each (alpine + static Go binary)
- [ ] Health check endpoints respond

---

#### PC-01.2: Helm Chart — Base Structure

**Estimate**: M (2–3 days)
**Files to create**:

```
deploy/helm/lalo/
├── Chart.yaml
├── values.yaml                 # Default values
├── values-vn.yaml              # Vietnam overrides
├── values-sg.yaml              # Singapore overrides
├── templates/
│   ├── _helpers.tpl
│   ├── namespace.yaml
│   ├── configmap.yaml          # Shared config (call-config.yaml)
│   ├── secret.yaml             # External secret references
│   ├── signaling/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── hpa.yaml
│   │   └── pdb.yaml
│   ├── orchestrator/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── hpa.yaml
│   │   └── pdb.yaml
│   ├── policy/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── hpa.yaml
│   ├── push/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── hpa.yaml
│   ├── coturn/
│   │   ├── daemonset.yaml      # DaemonSet (not Deployment — needs host networking)
│   │   ├── service.yaml
│   │   └── configmap.yaml
│   ├── livekit/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── configmap.yaml
│   ├── nginx/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── configmap.yaml
│   │   └── ingress.yaml
│   └── jobs/
│       ├── migrate-postgres.yaml
│       └── migrate-clickhouse.yaml
```

**Key Design Decisions**:

- coturn as **DaemonSet** with `hostNetwork: true` (needs direct UDP access, port range 49152-65535)
- LiveKit as **Deployment** with anti-affinity (spread across nodes)
- Signaling/Orchestrator/Policy as **Deployments** with HPA
- Separate `values-{region}.yaml` for region-specific overrides (node pools, replicas, resource limits)

**Acceptance**:

- [ ] `helm template` renders valid K8s manifests
- [ ] `helm lint` passes
- [ ] Region-specific values override defaults correctly

---

### Wave 1 — Infrastructure (Depends on Wave 0)

#### PC-01.3: Terraform — Cloud Infrastructure

**Estimate**: L (4–5 days)
**Files to create**:

```
deploy/terraform/
├── main.tf
├── variables.tf
├── outputs.tf
├── versions.tf
├── environments/
│   ├── production/
│   │   ├── main.tf
│   │   ├── terraform.tfvars
│   │   └── backend.tf
│   └── staging/
│       ├── main.tf
│       ├── terraform.tfvars
│       └── backend.tf
├── modules/
│   ├── k8s-cluster/           # K8s cluster per region
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── node-pools.tf
│   ├── database/              # Postgres + ClickHouse
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── replication.tf     # Cross-region streaming replication
│   ├── redis/                 # Redis cluster per region
│   │   ├── main.tf
│   │   └── variables.tf
│   ├── nats/                  # NATS cluster per region
│   │   ├── main.tf
│   │   └── variables.tf
│   ├── networking/            # VPC, subnets, peering
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── vpc-peering.tf     # Cross-region VPC peering
│   ├── dns/                   # GeoDNS setup
│   │   ├── main.tf
│   │   └── variables.tf
│   └── observability/         # Monitoring infra
│       ├── main.tf
│       └── variables.tf
```

**Cloud Provider Decision** (needs user input):

- Option A: AWS (EKS, RDS, ElastiCache, Route53 for GeoDNS)
- Option B: GCP (GKE, Cloud SQL, Memorystore, Cloud DNS)
- Option C: DigitalOcean/Vultr (cheaper, simpler, manual HA)

**Per-Region Resources**:

| Resource          | Vietnam (Primary)   | Singapore (Secondary) |
| ----------------- | ------------------- | --------------------- |
| K8s cluster       | 3 AZ, 6-8 nodes     | 3 AZ, 4-6 nodes       |
| Node pool — app   | 4 vCPU, 8GB × 3-4   | 4 vCPU, 8GB × 2-3     |
| Node pool — media | 8 vCPU, 16GB × 3-4  | 8 vCPU, 16GB × 2-3    |
| Postgres          | Primary (16GB, SSD) | Read replica          |
| Redis             | 6-node cluster      | 6-node cluster        |
| NATS              | 3-node JetStream    | 3-node JetStream      |
| ClickHouse        | 2-node cluster      | 2-node cluster        |

**Acceptance**:

- [ ] `terraform plan` succeeds for both regions
- [ ] VPC peering between regions established
- [ ] K8s clusters accessible via kubeconfig

---

#### PC-01.4: Container Registry + CI/CD Pipeline

**Estimate**: M (2–3 days)
**Files to modify/create**:

- `.github/workflows/ci.yml` — extend with container build + push
- `.github/workflows/deploy.yml` — new: deploy to K8s per region

**CI/CD Flow**:

```
Push to main
  → Build + test (existing)
  → Build Docker images (4 services)
  → Push to container registry (ECR/GCR/GHCR)
  → Deploy to staging (auto)
  → Deploy to production (manual approval)
    → Deploy to VN region first (canary)
    → Wait 10 min + health check
    → Deploy to SG region
```

**Acceptance**:

- [ ] Images built and pushed on merge to main
- [ ] Deploy workflow deploys to correct region
- [ ] Rollback mechanism works (`helm rollback`)

---

### Wave 2 — Networking & Data (Depends on Wave 1)

#### PC-01.5: GeoDNS Configuration

**Estimate**: M (2–3 days)

**DNS Records**:

| Domain            | Type | Routing       | Targets                        |
| ----------------- | ---- | ------------- | ------------------------------ |
| `signal.lalo.app` | A    | Latency-based | VN LB IP, SG LB IP             |
| `turn.lalo.app`   | A    | Latency-based | VN coturn IPs, SG coturn IPs   |
| `api.lalo.app`    | A    | Latency-based | VN LB IP, SG LB IP             |
| `sfu.lalo.app`    | A    | Latency-based | VN LiveKit IPs, SG LiveKit IPs |

**Health Checks**:

- HTTP health check on signaling `/healthz` every 10s
- TCP health check on coturn port 3478 every 10s
- Failover: remove unhealthy region from DNS (TTL 30s)

**Acceptance**:

- [ ] DNS resolves to nearest region based on client location
- [ ] Unhealthy region removed from rotation within 60s
- [ ] Failover tested manually (kill one region → traffic shifts)

---

#### PC-01.6: Database Replication

**Estimate**: L (3–4 days)

**Postgres**:

- Primary in Vietnam, streaming replication to Singapore
- Read replica for read-heavy queries (call history, user lookup)
- All writes go to Vietnam primary
- Promotion runbook for disaster recovery

**ClickHouse**:

- Distributed tables across both regions
- Each region writes locally, reads can query both
- ReplicatedMergeTree engine for HA within region

**Redis**:

- Independent clusters per region (session data is region-local)
- No cross-region replication needed (sessions are ephemeral)

**NATS**:

- Per-region JetStream cluster
- NATS Gateway for cross-region event delivery (call signaling, presence)
- Leaf node configuration for inter-region communication

**Acceptance**:

- [ ] Postgres replication lag < 1s under normal load
- [ ] ClickHouse queries return data from both regions
- [ ] NATS cross-region message delivery works
- [ ] Redis operates independently per region

---

### Wave 3 — Application Changes (Depends on Wave 2)

#### PC-01.7: Region-Aware Backend Configuration

**Estimate**: M (2–3 days)
**Files to modify**:

- `configs/call-config.yaml` → region-aware config structure
- `internal/config/` → add region config loading
- `internal/signaling/` → region-aware TURN/SFU selection
- `internal/orchestrator/` → region-aware room creation

**Changes**:

1. Config: add `region` field, per-region TURN/SFU endpoints
2. Signaling: return region-local TURN servers to clients
3. Orchestrator: create LiveKit rooms in caller's region
4. Cross-region calls: both participants use their local coturn/SFU

**Acceptance**:

- [ ] Services start with region config
- [ ] TURN candidates returned match client's region
- [ ] LiveKit rooms created in correct region
- [ ] Cross-region call connects through each participant's local media plane

---

#### PC-01.8: Health Check & Readiness Probes

**Estimate**: S (1 day)
**Files to modify**:

- `internal/signaling/server.go` → add `/healthz`, `/readyz`
- `internal/orchestrator/server.go` → add `/healthz`, `/readyz`
- `internal/policy/server.go` → add `/healthz`, `/readyz`
- `cmd/push/` → add `/healthz`, `/readyz`

**Health Check Contract**:

```
GET /healthz → 200 OK (process alive)
GET /readyz  → 200 OK (dependencies connected: Redis, NATS, Postgres)
               503 Service Unavailable (dependency down)
```

**Acceptance**:

- [ ] All services expose `/healthz` and `/readyz`
- [ ] `/readyz` returns 503 when Redis/NATS/Postgres down
- [ ] K8s liveness/readiness probes configured in Helm

---

### Wave 4 — Validation & Runbooks (Depends on Wave 3)

#### PC-01.9: Deployment Validation Script

**Estimate**: M (2–3 days)
**Files to create**:

- `scripts/validate-deployment.sh`
- `scripts/failover-test.sh`

**Validation checks**:

1. All pods running and ready in both regions
2. DNS resolves correctly from both regions
3. Signaling WebSocket connects from both regions
4. TURN allocation works from both regions
5. Cross-region NATS message delivery
6. Postgres replication lag
7. End-to-end call test (same region)
8. End-to-end call test (cross region)

**Acceptance**:

- [ ] Script runs and reports status for all checks
- [ ] Failover test: disable one region, verify traffic shifts

---

#### PC-01.10: Operations Runbook

**Estimate**: S (1 day)
**Files to create**:

- `docs/runbook-multi-region.md`

**Contents**:

1. Region deployment procedure
2. Region failover procedure
3. Postgres failover (promote replica)
4. Scaling procedures (add nodes, increase replicas)
5. Rollback procedures
6. Monitoring dashboards & alert response
7. Troubleshooting guide

**Acceptance**:

- [ ] Runbook covers all operational scenarios
- [ ] Reviewed by team

---

## Dependency Graph

```
Wave 0 (parallel):
  PC-01.1 (Dockerfiles)    ───┐
  PC-01.2 (Helm Chart)     ───┤
                               │
Wave 1 (parallel):             │
  PC-01.3 (Terraform) ←───────┤
  PC-01.4 (CI/CD)     ←───────┘
         │
Wave 2 (parallel):
  PC-01.5 (GeoDNS)      ←── PC-01.3
  PC-01.6 (DB Replication) ←── PC-01.3
         │
Wave 3 (parallel):
  PC-01.7 (Region Config)   ←── PC-01.6
  PC-01.8 (Health Checks)   ←── PC-01.2
         │
Wave 4 (parallel):
  PC-01.9 (Validation)   ←── PC-01.5, PC-01.7
  PC-01.10 (Runbook)      ←── PC-01.9
```

## Timeline Estimate

| Wave      | Tasks             | Duration     | Parallel |
| --------- | ----------------- | ------------ | -------- |
| Wave 0    | PC-01.1, PC-01.2  | 3 days       | Yes      |
| Wave 1    | PC-01.3, PC-01.4  | 5 days       | Yes      |
| Wave 2    | PC-01.5, PC-01.6  | 4 days       | Yes      |
| Wave 3    | PC-01.7, PC-01.8  | 3 days       | Yes      |
| Wave 4    | PC-01.9, PC-01.10 | 3 days       | Yes      |
| **Total** |                   | **~18 days** | ~3 weeks |

## Open Decisions (Need User Input)

| #   | Question                              | Options                             | Impact   |
| --- | ------------------------------------- | ----------------------------------- | -------- |
| 1   | Cloud provider?                       | AWS / GCP / DigitalOcean / Other    | All IaC  |
| 2   | Container registry?                   | ECR / GCR / GHCR / DockerHub        | CI/CD    |
| 3   | Managed vs self-hosted databases?     | Managed (RDS/Cloud SQL) vs K8s pods | Cost/ops |
| 4   | Domain for production?                | lalo.app / other                    | DNS      |
| 5   | Start with staging environment first? | Yes / No                            | Timeline |

---

_This plan should be reviewed and decisions made before implementation begins._
