# TRA-924 Retire Browser MQTT (infra slice) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retire the TRA-902 browser-direct MQTT footprint — disable the broker WSS listener + public `:8084` LB exposure, retire the `frontend-readonly` identity, and remove the backend `readerFeed` runtime config — now that Live Reads moves to a backend SSE proxy (platform repo).

**Architecture:** Pure config/template reversal across `helm/trakrf-mosquitto`, `helm/trakrf-backend`, `argocd/root`, and the `justfile`. The WSS listener, its container port, and its LB port are all gated on `.Values.websocket.enabled`, so flipping it to `false` removes all three at once; the `:8883` MQTT path, static LB IPs, and `trakrf-mqtt` user are untouched. No Terraform/Tofu change.

**Tech Stack:** Helm, ArgoCD app-of-apps (`argocd/root`), `just`, Mosquitto config. Verification via `helm lint`/`helm template` (CI-equivalent) and recipe parse — no unit-test framework applies.

**Spec:** `docs/superpowers/specs/2026-06-04-tra-924-retire-browser-mqtt-design.md`

---

## File Structure

- `helm/trakrf-mosquitto/values.yaml` — flip `websocket.enabled` to `false`; update comment.
- `helm/trakrf-mosquitto/templates/mosquitto-configmap.yaml` — update inert WSS-block comment; drop `frontend-readonly` ACL stanza + refresh the ACL comment.
- `helm/trakrf-backend/values.yaml` — delete `readerFeed` block + doc comment.
- `helm/trakrf-backend/templates/deployment.yaml` — delete `READER_FEED_MQTT_*` env block.
- `argocd/root/templates/trakrf-backend.yaml` — delete `readerFeed.url` inject.
- `argocd/root/values.yaml` — delete `readerFeedEnabled` from preview/prod + doc comment.
- `justfile` — drop `frontend-readonly` provisioning from `mosquitto-secrets` + its header doc.

Deployment.yaml and mqtt-service.yaml in the mosquitto chart need **no** edits — their `wss` ports are already gated on `.Values.websocket.enabled`.

---

### Task 1: Disable WSS + retire `frontend-readonly` ACL (trakrf-mosquitto)

**Files:**
- Modify: `helm/trakrf-mosquitto/values.yaml`
- Modify: `helm/trakrf-mosquitto/templates/mosquitto-configmap.yaml`

- [ ] **Step 1: Flip `websocket.enabled` to false**

In `helm/trakrf-mosquitto/values.yaml`, replace the `websocket` block:

```yaml
# WSS listener retired by TRA-924 — Live Reads moved to a backend SSE proxy
# (org-enforced), so nothing connects to the broker from the browser anymore.
# Disabled gates off the :8084 listener, its container port, AND the public
# LoadBalancer wss port together. Kept as inert config for cheap reversibility;
# if ever re-enabled it would be a cluster-internal listener only — do not
# re-expose it on the public LB without revisiting the TRA-924 threat model.
websocket:
  enabled: false
  port: 8084
```

- [ ] **Step 2: Update the inert WSS listener comment in the configmap**

In `helm/trakrf-mosquitto/templates/mosquitto-configmap.yaml`, replace the comment above the `{{- if .Values.websocket.enabled }}` listener block (keep the templated listener itself unchanged):

```
    {{- if .Values.websocket.enabled }}

    # WebSocket (TLS) listener — RETIRED by TRA-924 (disabled via
    # websocket.enabled=false). Live Reads moved to a backend SSE proxy; nothing
    # connects to the broker from the browser. Block kept inert for reversibility.
    # NOTE: the `frontend-readonly` user no longer exists — re-enabling this
    # listener would need a fresh ACL identity and must stay cluster-internal.
    listener {{ .Values.websocket.port }} 0.0.0.0
```

- [ ] **Step 3: Drop the `frontend-readonly` stanza from the ACL block**

In the same file, replace the `acl` block's comment + body so only `trakrf-mqtt` remains:

```yaml
  # Per-user ACL applied on the public :8883 listener. The loopback :1883
  # listener has no acl_file, so the metrics exporter's $SYS reads stay
  # unrestricted. trakrf-mqtt stays broad (backend subscriber + TRA-906 command
  # publisher + readers — unchanged). The TRA-902 `frontend-readonly` user was
  # retired in TRA-924 (browser no longer touches the broker). TRA-857 tracks
  # tighter per-user scoping.
  acl: |
    user trakrf-mqtt
    topic readwrite #
```

- [ ] **Step 4: Lint + template, assert WSS and frontend-readonly are gone**

Run:
```bash
helm lint helm/trakrf-mosquitto -f helm/trakrf-mosquitto/values.yaml -f helm/trakrf-mosquitto/values-gke.yaml
helm template helm/trakrf-mosquitto -f helm/trakrf-mosquitto/values.yaml -f helm/trakrf-mosquitto/values-gke.yaml | grep -E "8084|websockets|frontend-readonly|name: wss" || echo "NONE — expected"
```
Expected: lint passes (1 chart linted, 0 failures); the grep prints `NONE — expected` (no `:8084` listener, no `websockets` protocol line, no `frontend-readonly`, no `wss` port). Confirm `8883` + `trakrf-mqtt` still present:
```bash
helm template helm/trakrf-mosquitto -f helm/trakrf-mosquitto/values.yaml -f helm/trakrf-mosquitto/values-gke.yaml | grep -E "listener 8883|user trakrf-mqtt"
```
Expected: both lines present.

- [ ] **Step 5: Commit**

```bash
git add helm/trakrf-mosquitto/values.yaml helm/trakrf-mosquitto/templates/mosquitto-configmap.yaml
git commit -m "feat(trakrf-mosquitto): disable WSS listener + retire frontend-readonly ACL (TRA-924)"
```

---

### Task 2: Drop `frontend-readonly` provisioning from `just mosquitto-secrets`

**Files:**
- Modify: `justfile`

- [ ] **Step 1: Remove the `MOSQUITTO_FRONTEND_*` doc block from the recipe header**

In `justfile`, delete these lines from the `mosquitto-secrets` header comment:

```
#   MOSQUITTO_FRONTEND_USER      (optional) read-only frontend user; default
#                        frontend-readonly. Subscribe-only on trakrf.id/+/reads
#                        (acl in the trakrf-mosquitto chart). TRA-902 reader feed.
#   MOSQUITTO_FRONTEND_PASSWORD  (optional) if set, a 2nd user is added to the
#                        password_file + literal creds to the Secret
#                        (frontend_username/frontend_password) for the public
#                        VITE bundle. Unset → skipped.
#
```

- [ ] **Step 2: Remove the frontend user from the passwd build + the frontend_* Secret keys**

Replace the recipe body's build/apply block (the `@# Use a throwaway...` comment through the `--dry-run=client -o yaml | kubectl apply -f -` line) with the `frontend-readonly` parts removed:

```make
    @# Use a throwaway eclipse-mosquitto container so we don't depend on a host
    @# mosquitto_passwd binary. Builds the hashed password_file for the shared
    @# trakrf-mqtt user, then folds it into a Secret alongside the literal creds.
    @PASSWD_FILE=$(docker run --rm eclipse-mosquitto:2.0.21 sh -c \
      "mosquitto_passwd -b -c /tmp/passwd '${MOSQUITTO_USER}' '${MOSQUITTO_PASSWORD}' >/dev/null; \
       cat /tmp/passwd") && \
     kubectl create secret generic trakrf-mosquitto-auth -n trakrf-system \
       --from-literal=passwd="$PASSWD_FILE" \
       --from-literal=username="${MOSQUITTO_USER}" \
       --from-literal=password="${MOSQUITTO_PASSWORD}" \
       --dry-run=client -o yaml | kubectl apply -f -
```

- [ ] **Step 3: Verify the justfile parses and the recipe no longer references frontend**

Run:
```bash
just --summary >/dev/null && echo "PARSE OK"
just --show mosquitto-secrets | grep -i frontend || echo "NONE — expected"
```
Expected: `PARSE OK`, then `NONE — expected` (no `frontend` references remain).

- [ ] **Step 4: Commit**

```bash
git add justfile
git commit -m "feat(justfile): retire frontend-readonly broker user from mosquitto-secrets (TRA-924)"
```

---

### Task 3: Remove backend `readerFeed` wiring (helm/trakrf-backend)

**Files:**
- Modify: `helm/trakrf-backend/values.yaml`
- Modify: `helm/trakrf-backend/templates/deployment.yaml`

- [ ] **Step 1: Delete the `readerFeed` env block from the Deployment**

In `helm/trakrf-backend/templates/deployment.yaml`, delete the entire block (the `{{- if .Values.readerFeed.url }}` through its matching `{{- end }}`, including the comment and all four `READER_FEED_MQTT_*` env entries). The `envFrom:` line that follows stays.

- [ ] **Step 2: Delete the `readerFeed` values block + doc comment**

In `helm/trakrf-backend/values.yaml`, delete the `readerFeed:` block and its leading doc comment (the paragraph starting `# (window.__APP_CONFIG__.readerFeed) ...` through `passwordSecretKey: frontend_password`). Leave the `# Non-secret config (ConfigMap)` section that follows intact.

- [ ] **Step 3: Lint + template, assert READER_FEED is gone**

Run:
```bash
helm lint helm/trakrf-backend -f helm/trakrf-backend/values.yaml -f helm/trakrf-backend/values-gke.yaml
helm template helm/trakrf-backend -f helm/trakrf-backend/values.yaml -f helm/trakrf-backend/values-gke.yaml | grep -i "READER_FEED\|readerFeed" || echo "NONE — expected"
```
Expected: lint passes; grep prints `NONE — expected`.

- [ ] **Step 4: Commit**

```bash
git add helm/trakrf-backend/values.yaml helm/trakrf-backend/templates/deployment.yaml
git commit -m "feat(trakrf-backend): remove readerFeed env wiring (TRA-924)"
```

---

### Task 4: Remove `readerFeedEnabled` from argocd/root

**Files:**
- Modify: `argocd/root/templates/trakrf-backend.yaml`
- Modify: `argocd/root/values.yaml`

- [ ] **Step 1: Delete the `readerFeed.url` inject from the backend template**

In `argocd/root/templates/trakrf-backend.yaml`, delete the TRA-902 block (the `{{- /* TRA-902: reader live-view feed... */ -}}` comment, the `{{- if and $cfg.readerFeedEnabled (eq $.Values.cluster "gke") }}` line, its `$base = printf ...readerFeed...` line, and the matching `{{- end }}`). The `$ingress := ...` line that follows stays.

- [ ] **Step 2: Delete `readerFeedEnabled` from preview + prod + the doc comment**

In `argocd/root/values.yaml`:
- Delete the `# readerFeedEnabled ...` doc-comment paragraph (lines beginning `# readerFeedEnabled            — TRA-902:` through the end of that paragraph).
- Delete `    readerFeedEnabled: true  # TRA-902: Live Reads tab WSS feed` from the `preview` env.
- Delete `    readerFeedEnabled: false  # Live Reads stays off until the multi-tenant gate (see TRA-902)` from the `prod` env.

- [ ] **Step 3: Render the root chart, assert readerFeed is gone**

Run:
```bash
helm template trakrf-root argocd/root -f argocd/root/values.yaml --set cluster=gke | grep -i readerFeed || echo "NONE — expected"
helm template trakrf-root argocd/root -f argocd/root/values.yaml --set cluster=gke >/dev/null && echo "RENDER OK"
```
Expected: `NONE — expected`, then `RENDER OK`. (If the root chart needs cluster-specific values files, mirror the CI invocation from `.github/workflows/ci.yml` instead.)

- [ ] **Step 4: Commit**

```bash
git add argocd/root/templates/trakrf-backend.yaml argocd/root/values.yaml
git commit -m "feat(argocd-root): drop readerFeedEnabled per-env flag (TRA-924)"
```

---

### Task 5: Full verification + PR

- [ ] **Step 1: Re-run the full CI-equivalent helm matrix locally**

Run (mirror `.github/workflows/ci.yml`):
```bash
# backend (default + gke + aks/eks per CI matrix)
helm lint helm/trakrf-backend -f helm/trakrf-backend/values.yaml -f helm/trakrf-backend/values-gke.yaml
helm template helm/trakrf-backend -f helm/trakrf-backend/values.yaml -f helm/trakrf-backend/values-gke.yaml >/dev/null
# mosquitto (gke)
helm lint helm/trakrf-mosquitto -f helm/trakrf-mosquitto/values.yaml -f helm/trakrf-mosquitto/values-gke.yaml
helm template helm/trakrf-mosquitto -f helm/trakrf-mosquitto/values.yaml -f helm/trakrf-mosquitto/values-gke.yaml >/dev/null
# root
helm template trakrf-root argocd/root -f argocd/root/values.yaml --set cluster=gke >/dev/null
```
Expected: all lint pass, all templates render without error. Match the exact value-file flags CI uses (read `.github/workflows/ci.yml`).

- [ ] **Step 2: Push the branch + open the PR**

```bash
git push -u origin worktree-miks2u+tra-902-backend-reader-feed-env
gh pr create --title "feat(infra): retire browser MQTT — disable broker WSS + frontend-readonly (TRA-924)" --body "<see PR body>"
```

- [ ] **Step 3: HOLD — do not merge.** Report the PR URL and wait for approval (per request). Post-merge runbook to include in the PR body: re-run `just mosquitto-secrets` to regenerate the live `passwd`/Secret without `frontend-readonly`.

---

## Self-Review

- **Spec coverage:** WSS disable (Task 1) ✓; frontend-readonly ACL retire (Task 1) ✓; provisioning retire (Task 2) ✓; backend readerFeed env (Task 3) ✓; argocd readerFeedEnabled (Task 4) ✓; no-Tofu-change (asserted, no task needed) ✓; verification + PR + hold (Task 5) ✓. No gaps.
- **Placeholder scan:** PR body is `<see PR body>` — authored at execution time from the spec; all config edits show exact content. No TBD/TODO in code steps.
- **Type consistency:** value keys (`websocket.enabled`, `readerFeed.url`, `readerFeedEnabled`) match the files read during planning. `frontend-readonly` spelled consistently.
