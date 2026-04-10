# ArgoCD Install & GitOps Application Manifests — Design Spec

**Linear issue:** [TRA-355](https://linear.app/trakrf/issue/TRA-355/m1-argocd-install-gitops-application-manifests)
**Date:** 2026-04-10
**Author:** Mike Stankavich
**Status:** Draft

## Goal

Install ArgoCD on the EKS cluster (`trakrf-demo`) and configure an app-of-apps GitOps pattern so all TrakRF workloads are deployed and managed through git commits to this repo.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Bootstrap method | Helm via justfile, then self-manage | Avoids Terraform/ArgoCD ownership conflict. Standard GitOps pattern. |
| Self-management | App-of-apps | ArgoCD manages itself + all workloads from `argocd/` directory |
| App discovery | Directory of Application manifests (not ApplicationSet) | Only 3-4 apps; explicit YAML is simpler to reason about and debug |
| Helm values | Minimal (IRSA + resource limits) | No HA, no ingress, no SSO for demo. Add later via git commit. |
| Access | Port-forward | No LB controller in scope (per TRA-352 design) |
| Namespaces | `argocd`, `crunchy-postgres`, `trakrf`, `monitoring` | Matches IRSA roles; operator isolated from app workloads |

## Namespace Layout

| Namespace | Purpose |
|-----------|---------|
| `argocd` | ArgoCD server, repo-server, application-controller |
| `crunchy-postgres` | CrunchyData PGO operator (manages Postgres instances in other namespaces) |
| `trakrf` | TrakRF backend + Postgres/TimescaleDB clusters created by PGO |
| `monitoring` | kube-prometheus-stack (Prometheus, Grafana, Alertmanager) |

## Directory Structure

```
argocd/
├── bootstrap/
│   └── values.yaml          # Helm values for initial ArgoCD install
├── applications/
│   ├── argocd.yaml           # ArgoCD self-management Application
│   ├── crunchy-postgres.yaml # CrunchyData PGO operator
│   ├── trakrf-backend.yaml   # TrakRF backend (placeholder)
│   └── kube-prometheus.yaml  # kube-prometheus-stack
├── projects/
│   └── trakrf.yaml           # AppProject definition
└── root.yaml                 # Root app-of-apps Application
```

## Bootstrap Flow

1. `just argocd-bootstrap` runs:
   - `helm repo add argo https://argoproj.github.io/argo-helm`
   - `helm install argocd argo/argo-cd -n argocd --create-namespace -f argocd/bootstrap/values.yaml`
   - `kubectl apply -f argocd/root.yaml`
2. ArgoCD starts, discovers `root.yaml` pointing at `argocd/applications/`
3. ArgoCD picks up all child Applications, including its own self-management app
4. From this point, changes to ArgoCD config or workloads are git commits — ArgoCD syncs automatically

**Access:** `kubectl port-forward svc/argocd-server -n argocd 8080:443`

**Initial password:** `just argocd-password` fetches from the auto-generated secret.

## Bootstrap Values (`bootstrap/values.yaml`)

Minimal Helm values:

- IRSA annotation on `argocd-server` service account (uses existing stub role from `iam.tf`)
- Resource requests/limits for server, repo-server, and application-controller
- All other settings left at defaults (no HA, no ingress, no Dex/SSO)

## AppProject

Single project `trakrf` (`projects/trakrf.yaml`):

- Source repo: `git@github.com:trakrf/infra.git`
- Destinations restricted to: `argocd`, `crunchy-postgres`, `trakrf`, `monitoring`
- Cluster-scoped resources allowed (CrunchyData and prometheus-operator both install CRDs)

## Application Manifests

### Root Application (`root.yaml`)

- Name: `root`
- Project: `default` (manages the AppProject definition itself)
- Source: `argocd/applications/` directory in this repo
- Sync policy: manual (applied once via kubectl, then manages child apps)

### Child Applications (`argocd/applications/`)

| Application | Source | Target Namespace | Sync Policy |
|------------|--------|-----------------|-------------|
| `argocd` | `argo/argo-cd` Helm chart + `bootstrap/values.yaml` | `argocd` | Auto-sync (self-managed) |
| `crunchy-postgres` | CrunchyData PGO Helm chart | `crunchy-postgres` | Auto-sync |
| `trakrf-backend` | `argocd/charts/trakrf-backend/` in this repo (placeholder) | `trakrf` | Manual sync |
| `kube-prometheus` | `prometheus-community/kube-prometheus-stack` Helm chart | `monitoring` | Auto-sync |

**Notes:**

- `trakrf-backend` is a placeholder — the Application manifest defines the target structure but the chart doesn't exist yet. It will show as degraded in ArgoCD until the chart is created, which is expected.
- `crunchy-postgres` installs the PGO operator only. Actual Postgres/TimescaleDB cluster definitions come with TRA-353.
- `kube-prometheus-stack` installs Prometheus, Grafana, and Alertmanager with defaults.

## Terraform Changes

Rename CrunchyData IRSA namespace in `terraform/aws/iam.tf`:

```hcl
# Before
namespace_service_accounts = ["crunchy-system:crunchy-operator"]

# After
namespace_service_accounts = ["crunchy-postgres:crunchy-operator"]
```

Requires `tofu apply` before deploying the operator.

## Justfile Commands

| Command | Action |
|---------|--------|
| `just argocd-bootstrap` | Helm install ArgoCD + apply root app |
| `just argocd-password` | Fetch initial admin password |

## Out of Scope

- AWS Load Balancer Controller / ingress for ArgoCD UI
- SSO / Dex / Kanidm integration
- HA mode for ArgoCD
- ApplicationSet or multi-cluster
- Actual Postgres cluster definitions (TRA-353)
- TrakRF backend Helm chart (separate ticket)

## Acceptance Criteria

- ArgoCD running in `argocd` namespace via `just argocd-bootstrap`
- Root app-of-apps Application discovers all child apps
- ArgoCD self-management Application syncs successfully
- CrunchyData PGO, kube-prometheus-stack Applications defined (sync depends on chart availability)
- `trakrf-backend` placeholder Application present
- AppProject restricts deployments to defined namespaces
- IRSA namespace updated in Terraform and applied
- Port-forward provides access to ArgoCD UI
