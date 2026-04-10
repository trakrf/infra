# ArgoCD Install & GitOps Application Manifests — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install ArgoCD on EKS via Helm and configure app-of-apps GitOps pattern for all TrakRF workloads.

**Architecture:** Bootstrap ArgoCD with Helm via justfile, then hand control to ArgoCD itself via a root app-of-apps Application. Child Applications for ArgoCD (self-managed), CrunchyData PGO, kube-prometheus-stack, and TrakRF backend (placeholder). A single AppProject scopes all deployments.

**Tech Stack:** ArgoCD Helm chart (`argo/argo-cd` ~9.5), CrunchyData PGO (`oci://registry.developers.crunchydata.com/crunchydata/pgo`), kube-prometheus-stack (`prometheus-community/kube-prometheus-stack` ~83.x), OpenTofu, justfile.

**Linear issue:** [TRA-355](https://linear.app/trakrf/issue/TRA-355/m1-argocd-install-gitops-application-manifests)

---

## File Structure

```
argocd/
├── bootstrap/
│   └── values.yaml              # Helm values for ArgoCD bootstrap install
├── applications/
│   ├── argocd.yaml              # ArgoCD self-management Application
│   ├── crunchy-postgres.yaml    # CrunchyData PGO operator Application
│   ├── trakrf-backend.yaml      # TrakRF backend Application (placeholder)
│   └── kube-prometheus.yaml     # kube-prometheus-stack Application
├── projects/
│   └── trakrf.yaml              # AppProject definition
└── root.yaml                    # Root app-of-apps Application

terraform/aws/
└── iam.tf                       # Modify: rename crunchy-system → crunchy-postgres

justfile                         # Modify: add argocd-bootstrap and argocd-password recipes
```

---

### Task 1: Update IRSA namespace for CrunchyData

The existing IRSA role in `iam.tf` references `crunchy-system`. Update to `crunchy-postgres` to match the namespace layout.

**Files:**
- Modify: `terraform/aws/iam.tf:28` (namespace_service_accounts line)

- [ ] **Step 1: Update the namespace in iam.tf**

In `terraform/aws/iam.tf`, change the CrunchyData IRSA module's `namespace_service_accounts`:

```hcl
# In module "crunchy_irsa", change:
namespace_service_accounts = ["crunchy-postgres:crunchy-operator"]
```

- [ ] **Step 2: Run tofu plan to verify**

```bash
just _backend-conf terraform/aws
tofu -chdir=terraform/aws init -backend-config=backend.conf
tofu -chdir=terraform/aws plan
```

Expected: Plan shows an in-place update to the `crunchy_irsa` IAM role trust policy, changing `crunchy-system` to `crunchy-postgres`. No resources destroyed.

- [ ] **Step 3: Commit**

```bash
git add terraform/aws/iam.tf
git commit -m "fix(aws): rename crunchy IRSA namespace to crunchy-postgres"
```

> **Note:** Do NOT run `tofu apply` yet — this will be applied together with the full PR.

---

### Task 2: ArgoCD bootstrap Helm values

Create the minimal Helm values file for the initial ArgoCD install.

**Files:**
- Create: `argocd/bootstrap/values.yaml`

**Reference:** The ArgoCD IRSA role ARN follows the pattern `arn:aws:iam::<account-id>:role/trakrf-demo-argocd`. The exact ARN is available via `tofu -chdir=terraform/aws output -json irsa_role_arns | jq -r .argocd`.

- [ ] **Step 1: Create bootstrap values file**

Create `argocd/bootstrap/values.yaml`:

```yaml
# ArgoCD Helm values — minimal bootstrap for trakrf-demo EKS cluster
# Chart: argo/argo-cd ~9.5
# After bootstrap, ArgoCD self-manages via app-of-apps pattern.
# Changes to these values take effect via the self-management Application in argocd/applications/argocd.yaml.

global:
  domain: ""  # No ingress — access via port-forward

server:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: "ARGOCD_IRSA_ROLE_ARN"
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 256Mi

controller:
  resources:
    requests:
      cpu: 250m
      memory: 256Mi
    limits:
      cpu: "1"
      memory: 512Mi

repoServer:
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 256Mi

redis:
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 128Mi

dex:
  enabled: false

notifications:
  enabled: false
```

- [ ] **Step 2: Verify YAML is valid**

```bash
python3 -c "import yaml; yaml.safe_load(open('argocd/bootstrap/values.yaml'))" && echo "Valid YAML"
```

Expected: `Valid YAML`

- [ ] **Step 3: Commit**

```bash
git add argocd/bootstrap/values.yaml
git commit -m "feat(argocd): add bootstrap Helm values for ArgoCD"
```

---

### Task 3: AppProject definition

Create the AppProject that scopes all TrakRF workloads.

**Files:**
- Create: `argocd/projects/trakrf.yaml`

- [ ] **Step 1: Create the AppProject manifest**

Create `argocd/projects/trakrf.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: trakrf
  namespace: argocd
spec:
  description: TrakRF platform workloads
  sourceRepos:
    - "git@github.com:trakrf/infra.git"
    - "https://argoproj.github.io/argo-helm"
    - "registry.developers.crunchydata.com/crunchydata/*"
    - "https://prometheus-community.github.io/helm-charts"
  destinations:
    - server: https://kubernetes.default.svc
      namespace: argocd
    - server: https://kubernetes.default.svc
      namespace: crunchy-postgres
    - server: https://kubernetes.default.svc
      namespace: trakrf
    - server: https://kubernetes.default.svc
      namespace: monitoring
  clusterResourceWhitelist:
    - group: "*"
      kind: CustomResourceDefinition
    - group: "*"
      kind: ClusterRole
    - group: "*"
      kind: ClusterRoleBinding
    - group: "admissionregistration.k8s.io"
      kind: MutatingWebhookConfiguration
    - group: "admissionregistration.k8s.io"
      kind: ValidatingWebhookConfiguration
    - group: "apiextensions.k8s.io"
      kind: "*"
  namespaceResourceBlacklist:
    - group: ""
      kind: ResourceQuota
    - group: ""
      kind: LimitRange
```

- [ ] **Step 2: Verify YAML is valid**

```bash
python3 -c "import yaml; yaml.safe_load(open('argocd/projects/trakrf.yaml'))" && echo "Valid YAML"
```

Expected: `Valid YAML`

- [ ] **Step 3: Commit**

```bash
git add argocd/projects/trakrf.yaml
git commit -m "feat(argocd): add trakrf AppProject definition"
```

---

### Task 4: Root app-of-apps Application

Create the root Application that discovers all child apps from `argocd/applications/`.

**Files:**
- Create: `argocd/root.yaml`

- [ ] **Step 1: Create the root Application manifest**

Create `argocd/root.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: git@github.com:trakrf/infra.git
    targetRevision: main
    path: argocd/applications
    directory:
      recurse: false
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

- [ ] **Step 2: Verify YAML is valid**

```bash
python3 -c "import yaml; yaml.safe_load(open('argocd/root.yaml'))" && echo "Valid YAML"
```

Expected: `Valid YAML`

- [ ] **Step 3: Commit**

```bash
git add argocd/root.yaml
git commit -m "feat(argocd): add root app-of-apps Application"
```

---

### Task 5: ArgoCD self-management Application

Create the Application that lets ArgoCD manage its own Helm release.

**Files:**
- Create: `argocd/applications/argocd.yaml`

- [ ] **Step 1: Create the ArgoCD self-management Application**

Create `argocd/applications/argocd.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd
  namespace: argocd
spec:
  project: trakrf
  source:
    repoURL: https://argoproj.github.io/argo-helm
    chart: argo-cd
    targetRevision: "9.5.*"
    helm:
      valueFiles: []
      values: |
        global:
          domain: ""
        server:
          serviceAccount:
            annotations:
              eks.amazonaws.com/role-arn: "ARGOCD_IRSA_ROLE_ARN"
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
        controller:
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: "1"
              memory: 512Mi
        repoServer:
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
        redis:
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
        dex:
          enabled: false
        notifications:
          enabled: false
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 2: Verify YAML is valid**

```bash
python3 -c "import yaml; yaml.safe_load(open('argocd/applications/argocd.yaml'))" && echo "Valid YAML"
```

Expected: `Valid YAML`

- [ ] **Step 3: Commit**

```bash
git add argocd/applications/argocd.yaml
git commit -m "feat(argocd): add ArgoCD self-management Application"
```

---

### Task 6: CrunchyData PGO operator Application

Create the Application for the CrunchyData Postgres operator.

**Files:**
- Create: `argocd/applications/crunchy-postgres.yaml`

- [ ] **Step 1: Create the CrunchyData PGO Application**

Create `argocd/applications/crunchy-postgres.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: crunchy-postgres
  namespace: argocd
spec:
  project: trakrf
  source:
    repoURL: registry.developers.crunchydata.com/crunchydata
    chart: pgo
    targetRevision: "5.*"
  destination:
    server: https://kubernetes.default.svc
    namespace: crunchy-postgres
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 2: Verify YAML is valid**

```bash
python3 -c "import yaml; yaml.safe_load(open('argocd/applications/crunchy-postgres.yaml'))" && echo "Valid YAML"
```

Expected: `Valid YAML`

- [ ] **Step 3: Commit**

```bash
git add argocd/applications/crunchy-postgres.yaml
git commit -m "feat(argocd): add CrunchyData PGO operator Application"
```

---

### Task 7: kube-prometheus-stack Application

Create the Application for the monitoring stack.

**Files:**
- Create: `argocd/applications/kube-prometheus.yaml`

- [ ] **Step 1: Create the kube-prometheus-stack Application**

Create `argocd/applications/kube-prometheus.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kube-prometheus
  namespace: argocd
spec:
  project: trakrf
  source:
    repoURL: https://prometheus-community.github.io/helm-charts
    chart: kube-prometheus-stack
    targetRevision: "83.*"
    helm:
      values: |
        prometheus:
          prometheusSpec:
            resources:
              requests:
                cpu: 200m
                memory: 512Mi
              limits:
                cpu: "1"
                memory: 1Gi
            retention: 7d
            storageSpec:
              volumeClaimTemplate:
                spec:
                  accessModes: ["ReadWriteOnce"]
                  resources:
                    requests:
                      storage: 10Gi
        grafana:
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
        alertmanager:
          alertmanagerSpec:
            resources:
              requests:
                cpu: 50m
                memory: 64Mi
              limits:
                cpu: 200m
                memory: 128Mi
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 2: Verify YAML is valid**

```bash
python3 -c "import yaml; yaml.safe_load(open('argocd/applications/kube-prometheus.yaml'))" && echo "Valid YAML"
```

Expected: `Valid YAML`

- [ ] **Step 3: Commit**

```bash
git add argocd/applications/kube-prometheus.yaml
git commit -m "feat(argocd): add kube-prometheus-stack Application"
```

---

### Task 8: TrakRF backend placeholder Application

Create the placeholder Application for the backend. This will show as degraded in ArgoCD until the chart is created — that's expected.

**Files:**
- Create: `argocd/applications/trakrf-backend.yaml`

- [ ] **Step 1: Create the TrakRF backend placeholder Application**

Create `argocd/applications/trakrf-backend.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: trakrf-backend
  namespace: argocd
  annotations:
    argocd.argoproj.io/description: "Placeholder — chart not yet created"
spec:
  project: trakrf
  source:
    repoURL: git@github.com:trakrf/infra.git
    targetRevision: main
    path: helm/trakrf-backend
  destination:
    server: https://kubernetes.default.svc
    namespace: trakrf
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 2: Verify YAML is valid**

```bash
python3 -c "import yaml; yaml.safe_load(open('argocd/applications/trakrf-backend.yaml'))" && echo "Valid YAML"
```

Expected: `Valid YAML`

- [ ] **Step 3: Commit**

```bash
git add argocd/applications/trakrf-backend.yaml
git commit -m "feat(argocd): add trakrf-backend placeholder Application"
```

---

### Task 9: Justfile bootstrap and password recipes

Add the `argocd-bootstrap` and `argocd-password` recipes to the justfile.

**Files:**
- Modify: `justfile` (append new recipes)

- [ ] **Step 1: Add argocd recipes to justfile**

Append the following to the end of `justfile`:

```just
# Install ArgoCD via Helm and apply root app-of-apps
argocd-bootstrap:
    @echo "Adding ArgoCD Helm repo..."
    @helm repo add argo https://argoproj.github.io/argo-helm
    @helm repo update argo
    @echo "Installing ArgoCD into argocd namespace..."
    @helm install argocd argo/argo-cd --namespace argocd --create-namespace -f argocd/bootstrap/values.yaml
    @echo "Waiting for ArgoCD server to be ready..."
    @kubectl rollout status deployment/argocd-server -n argocd --timeout=120s
    @echo "Applying root app-of-apps..."
    @kubectl apply -f argocd/projects/trakrf.yaml
    @kubectl apply -f argocd/root.yaml
    @echo "ArgoCD bootstrap complete. Run 'just argocd-password' for the admin password."

# Fetch ArgoCD initial admin password
argocd-password:
    @kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d && echo

# Port-forward ArgoCD UI to localhost:8080
argocd-ui:
    @echo "ArgoCD UI at https://localhost:8080 (admin / <just argocd-password>)"
    @kubectl port-forward svc/argocd-server -n argocd 8080:443
```

- [ ] **Step 2: Verify justfile syntax**

```bash
just --list
```

Expected: The new recipes `argocd-bootstrap`, `argocd-password`, and `argocd-ui` appear in the list.

- [ ] **Step 3: Commit**

```bash
git add justfile
git commit -m "feat(argocd): add bootstrap, password, and UI justfile recipes"
```

---

### Task 10: Clean up placeholder README and commit

Remove the placeholder README in `argocd/` now that real content exists.

**Files:**
- Delete: `argocd/README.md`

- [ ] **Step 1: Remove the placeholder README**

```bash
rm argocd/README.md
```

- [ ] **Step 2: Commit**

```bash
git add argocd/README.md
git commit -m "chore(argocd): remove placeholder README"
```

---

### Task 11: Validate all manifests with dry-run

Validate that all YAML manifests are well-formed and would be accepted by a Kubernetes API server (dry-run). This does NOT require ArgoCD to be running.

**Files:** None (validation only)

- [ ] **Step 1: Validate AppProject**

```bash
kubectl apply -f argocd/projects/trakrf.yaml --dry-run=client && echo "AppProject: OK"
```

Expected: `appproject.argoproj.io/trakrf created (dry run)` — note: this may warn that the CRD doesn't exist if ArgoCD hasn't been installed. That's fine — `--dry-run=client` only checks YAML structure.

- [ ] **Step 2: Validate root Application**

```bash
kubectl apply -f argocd/root.yaml --dry-run=client && echo "Root app: OK"
```

Expected: `application.argoproj.io/root created (dry run)`

- [ ] **Step 3: Validate all child Applications**

```bash
for f in argocd/applications/*.yaml; do
  kubectl apply -f "$f" --dry-run=client && echo "$f: OK"
done
```

Expected: Each file prints `OK`.

- [ ] **Step 4: Validate Helm values parse correctly**

```bash
helm template test argo/argo-cd -f argocd/bootstrap/values.yaml > /dev/null && echo "Helm template: OK"
```

Expected: `Helm template: OK` (requires `helm repo add argo https://argoproj.github.io/argo-helm` to have been run).

---

## Post-Implementation Notes

**Before applying to the live cluster:**
1. Push all commits as a PR branch and merge via PR (per CLAUDE.md: never push directly to main).
2. Run `just aws` to apply the IRSA namespace rename (Task 1) — this must happen before `just argocd-bootstrap`.
3. The `ARGOCD_IRSA_ROLE_ARN` placeholder in `bootstrap/values.yaml` and `applications/argocd.yaml` must be replaced with the actual role ARN from `tofu output -json irsa_role_arns | jq -r .argocd` before running the bootstrap.

**Bootstrap sequence:**
1. `just aws` (applies IRSA change)
2. Update the IRSA ARN in values files
3. `just argocd-bootstrap`
4. `just argocd-password` → log in at `https://localhost:8080` via `just argocd-ui`
