# TRA-493 Traefik Prom Scrape Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prometheus scrapes Traefik on every cluster (verified on GKE), emitting per-service HTTP histograms without writing any hand-rolled ServiceMonitor.

**Architecture:** Flip two chart-native switches (`metrics.prometheus.service.enabled`, `metrics.prometheus.serviceMonitor.enabled`) in the inline helm values for the upstream Traefik release. kube-prometheus-stack auto-discovers the SM (already configured for wide-open discovery).

**Tech Stack:** ArgoCD, Helm, Traefik helm chart v39.x, kube-prometheus-stack, Prometheus Operator CRDs.

**Spec:** `docs/superpowers/specs/2026-04-24-tra-493-traefik-metrics-design.md`

---

## File Structure

- **Modify:** `argocd/root/templates/traefik.yaml` — add `metrics.prometheus.service.enabled` and `metrics.prometheus.serviceMonitor.enabled` to the inline helm values block (outside the cluster-specific `if/else` chain).

No new files. No changes to `helm/traefik-config/`. No changes to `helm/monitoring/`.

---

## Task 1: Add chart-native metrics + ServiceMonitor

**Files:**
- Modify: `argocd/root/templates/traefik.yaml:28-30` (insert after `providers:` block, before the `{{- if eq .Values.cluster "aks" }}` guard)

- [ ] **Step 1: Edit the file**

Replace this block:

```yaml
        providers:
          kubernetesCRD:
            allowCrossNamespace: true
        {{- if eq .Values.cluster "aks" }}
```

With:

```yaml
        providers:
          kubernetesCRD:
            allowCrossNamespace: true
        # Chart-native Prometheus scrape: enable the dedicated ClusterIP
        # metrics Service + ServiceMonitor. kube-prometheus-stack discovers
        # the SM via wide-open selectors in helm/monitoring/values.yaml.
        metrics:
          prometheus:
            service:
              enabled: true
            serviceMonitor:
              enabled: true
        {{- if eq .Values.cluster "aks" }}
```

- [ ] **Step 2: Render the root chart locally for GKE to confirm YAML is well-formed**

Run:

```bash
cd /home/mike/trakrf-infra
helm template argocd/root/ \
  -f argocd/root/values.yaml \
  --set cluster=gke \
  --set traefikLbIp=1.2.3.4 \
  --set gcpProjectId=dummy \
  --set certManagerGcpServiceAccountEmail=dummy@dummy.iam.gserviceaccount.com \
  --set cloudDnsZoneName=dummy \
  --show-only templates/traefik.yaml
```

Expected output contains a `helm.values:` block with both of these lines under the Traefik Application:

```
        metrics:
          prometheus:
            service:
              enabled: true
            serviceMonitor:
              enabled: true
```

…and the GKE-specific `tolerations:` block is still present. No templating errors. If rendering fails, fix indentation — the inline block uses 8-space indentation (under `values: |`).

- [ ] **Step 3: Render for AKS to confirm the other cluster branch still works**

Run:

```bash
cd /home/mike/trakrf-infra
helm template argocd/root/ \
  -f argocd/root/values.yaml \
  --set cluster=aks \
  --set traefikLbIp=1.2.3.4 \
  --set mainResourceGroupName=dummy-rg \
  --show-only templates/traefik.yaml
```

Expected: same `metrics.prometheus` block appears; AKS-specific `azure-load-balancer-resource-group` annotation is still present; no `tolerations:` block.

- [ ] **Step 4: Commit**

```bash
cd /home/mike/trakrf-infra
git add argocd/root/templates/traefik.yaml
git commit -m "$(cat <<'EOF'
feat(traefik): enable chart-native Prometheus metrics + ServiceMonitor

Flips metrics.prometheus.service.enabled and
metrics.prometheus.serviceMonitor.enabled on the upstream Traefik
v39 release. Chart creates a dedicated ClusterIP metrics Service
(no LB exposure) and a ServiceMonitor; kube-prometheus-stack
discovers via wide-open SM selectors already set in
helm/monitoring/values.yaml.

Cluster-agnostic — identical on GKE and AKS. Verification on GKE
per cloud portfolio strategy.

TRA-493

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Push branch and open PR

**Files:** none (git + GitHub)

- [ ] **Step 1: Push the branch**

```bash
cd /home/mike/trakrf-infra
git push -u origin miks2u/tra-493-enable-traefik-prom-scrape-servicemonitor
```

Expected: branch pushed, tracking set.

- [ ] **Step 2: Open PR to main**

```bash
cd /home/mike/trakrf-infra
gh pr create --title "feat(traefik): chart-native Prom metrics + ServiceMonitor (TRA-493)" --body "$(cat <<'EOF'
## Summary
- Enables chart-native Prometheus metrics scrape on the upstream Traefik v39 release: `metrics.prometheus.service.enabled` and `metrics.prometheus.serviceMonitor.enabled` both flip to true.
- kube-prometheus-stack auto-discovers the ServiceMonitor via wide-open selectors already configured in `helm/monitoring/values.yaml`.
- No hand-rolled YAML; no changes in `helm/traefik-config/` or `helm/monitoring/`. 4 lines added to `argocd/root/templates/traefik.yaml`.
- Closes TRA-493 (child of TRA-492).

Design: `docs/superpowers/specs/2026-04-24-tra-493-traefik-metrics-design.md`
Plan: `docs/superpowers/plans/2026-04-24-tra-493-traefik-metrics.md`

## Test plan
- [ ] `helm template argocd/root/` renders for GKE with the new metrics block (done pre-merge)
- [ ] `helm template argocd/root/` renders for AKS with the new metrics block (done pre-merge)
- [ ] Post-merge: ArgoCD `traefik` app on GKE syncs Healthy
- [ ] Post-merge: dedicated Service `traefik-metrics` (or chart-chosen name) exists in `traefik` ns on GKE
- [ ] Post-merge: ServiceMonitor exists in `traefik` ns on GKE
- [ ] Post-merge: Prometheus target for Traefik is UP
- [ ] Post-merge: `traefik_service_requests_total` returns non-empty with `service=~"trakrf-.+"` labels on GKE
- [ ] AKS: change applied via ArgoCD, not verified (AKS on ice per cloud portfolio strategy)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR URL printed. Note it for the verification steps.

- [ ] **Step 3: Confirm PR checks pass (if any)**

Run:

```bash
cd /home/mike/trakrf-infra
gh pr checks
```

Expected: all checks green, or no checks configured. If checks fail, investigate — do not merge on red.

- [ ] **Step 4: Merge PR with `--merge` (per CLAUDE.md)**

**STOP HERE — ask user to merge.** Per CLAUDE.md: never push directly to main, and this agent should not merge without explicit approval. The user will review the PR and merge themselves, OR approve `gh pr merge --merge`.

If user says "merge it":

```bash
cd /home/mike/trakrf-infra
gh pr merge --merge
```

---

## Task 3: Verify on GKE demo (post-merge)

**Files:** none (kubectl against GKE)

**Assumption:** kubectl context is the GKE demo cluster. If not, run `gcloud container clusters get-credentials <name> --region <region> --project <project>` first.

- [ ] **Step 1: Wait for ArgoCD to sync the Traefik app**

Run:

```bash
kubectl -n argocd get application traefik -o jsonpath='{.status.sync.status},{.status.health.status},{.status.operationState.syncResult.revision}' ; echo
```

Expected: `Synced,Healthy,<new-commit-sha-prefix>`. If still `OutOfSync` or on an old revision, wait ~60s (ArgoCD auto-sync poll interval) and re-run.

- [ ] **Step 2: Confirm the metrics Service exists**

Run:

```bash
kubectl -n traefik get svc -l app.kubernetes.io/name=traefik
```

Expected: at least two Services visible — the main `traefik` LoadBalancer, plus a new ClusterIP Service for metrics (chart names it `traefik-metrics` — if the exact name differs, note it but don't panic). Both are OK.

- [ ] **Step 3: Confirm the ServiceMonitor exists**

Run:

```bash
kubectl -n traefik get servicemonitor
```

Expected: one ServiceMonitor, chart-default name (typically `traefik`). If missing, check the `traefik` ArgoCD Application for sync errors:

```bash
kubectl -n argocd get application traefik -o jsonpath='{.status.conditions}' ; echo
```

- [ ] **Step 4: Confirm Prometheus target is UP**

From a `trakrf`-ns pod that has `wget`:

```bash
POD=$(kubectl -n trakrf get pod -l 'app.kubernetes.io/name in (trakrf-backend,trakrf-ingester)' -o jsonpath='{.items[0].metadata.name}')
kubectl -n trakrf exec "$POD" -- wget -qO- \
  'http://kube-prometheus-stack-prometheus.monitoring.svc:9090/api/v1/targets?state=active' \
  | grep -o '"labels":{[^}]*traefik[^}]*}' | head -5
```

Expected: at least one target with `job="traefik"` or similar — the exact job name depends on the chart's SM defaults. A match means the target is active (filtering on `state=active` already means it's UP).

- [ ] **Step 5: Confirm metrics are flowing**

```bash
POD=$(kubectl -n trakrf get pod -l 'app.kubernetes.io/name in (trakrf-backend,trakrf-ingester)' -o jsonpath='{.items[0].metadata.name}')
kubectl -n trakrf exec "$POD" -- wget -qO- \
  'http://kube-prometheus-stack-prometheus.monitoring.svc:9090/api/v1/query?query=traefik_service_requests_total' \
  | head -200
```

Expected: JSON response with `"status":"success"` and a non-empty `"result":[...]` array. At least some entries have a `service` label matching `trakrf-.+` (backend, ingester, grafana, etc. — whatever is behind Traefik).

- [ ] **Step 6: Drive some traffic if `result` is empty**

If step 5 returned an empty result set, Traefik may not have seen any HTTP traffic yet. Generate some:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://api.gke.trakrf.app/health
curl -sS -o /dev/null -w '%{http_code}\n' https://grafana.gke.trakrf.app/login
```

Wait 30 seconds (one scrape interval) and re-run Step 5. Expected: non-empty result now.

---

## Task 4: Close out

- [ ] **Step 1: Update Linear issue TRA-493 with verification result**

Post a comment to TRA-493 summarizing: PR URL, merged commit SHA, GKE verification output (one Prometheus query result excerpt showing `traefik_service_requests_total` with a `service=~"trakrf-.+"` label).

Tool: `mcp__linear-server__save_comment` with `issueId=TRA-493` and the body above. Mark the issue Done.

- [ ] **Step 2: Clean up local branch**

```bash
cd /home/mike/trakrf-infra
git checkout main
git pull --ff-only
git branch -d miks2u/tra-493-enable-traefik-prom-scrape-servicemonitor
```

Expected: branch deleted cleanly. If it refuses ("not fully merged"), the PR merge method was not `--merge` or the local branch has commits not in main — investigate before force-deleting.

---

## Risk / Rollback

If GKE verification fails (e.g., ServiceMonitor doesn't get created, Prometheus target is DOWN, metrics are empty after driving traffic):

1. Identify the specific failure mode. Common suspects:
   - CRD missing (`monitoring.coreos.com/v1`): check `kubectl get crd servicemonitors.monitoring.coreos.com`
   - Port mismatch: inspect the rendered ServiceMonitor and confirm its `endpoints.port` matches the metrics Service's port name.
   - Wide-open discovery not actually wide-open: check `kubectl -n monitoring get prometheus -o yaml | grep -A3 serviceMonitorSelector`.
2. If the issue is in our config and a small follow-up fixes it, open a new PR.
3. If the issue requires debugging that will take time, revert the merge:

   ```bash
   cd /home/mike/trakrf-infra
   git revert <merge-commit-sha>
   git push origin main  # assuming user authorizes
   ```

   The change is additive (new Service, new SM); revert cleanly removes both.
