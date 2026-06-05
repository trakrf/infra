# TRA-902 Broker WSS + read-only ACL — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a WebSocket (WSS) listener and a read-only `frontend-readonly` ACL to the `trakrf-mosquitto` broker so the frontend can subscribe to the read feed from the browser (TRA-902).

**Architecture:** All changes live in `helm/trakrf-mosquitto` (chart) + the `just mosquitto-secrets` recipe. A new `:8084` `protocol websockets` listener reuses the existing LE cert and is exposed on the existing static-IP LoadBalancer. A new `acl_file` (per-listener on `:8883`/`:8084`, not loopback `:1883`) keeps `trakrf-mqtt` broad (`readwrite #`, no behavior change) and scopes `frontend-readonly` to `read trakrf.id/+/reads`. The frontend cred is an optional second user created by `just mosquitto-secrets`.

**Tech Stack:** Helm, eclipse-mosquitto 2.0.21, GKE L4 LoadBalancer, just/docker.

**Verification model:** no unit tests — the gate is `helm lint` + `helm template` assertions per task; live-broker behavior is verified post-merge on deploy.

**Spec:** `docs/superpowers/specs/2026-06-04-tra-902-broker-wss-readonly-acl-design.md`

---

### Task 1: Add `websocket` values

**Files:**
- Modify: `helm/trakrf-mosquitto/values.yaml`

- [ ] **Step 1: Add the values block** (after the `certSecret:` block, before `podSecurityContext:`)

```yaml
# WebSocket (WSS) listener for the browser reader live-view (TRA-902). mqtt.js
# over WSS from the frontend, reusing the :8883 LE cert (TLS terminates at
# mosquitto; the LB is L4 passthrough). Auth + ACL enforced (no anonymous).
# The frontend-readonly user that uses it is created by `just mosquitto-secrets`.
websocket:
  enabled: true
  port: 8084
```

- [ ] **Step 2: Verify** — `helm template m helm/trakrf-mosquitto -f helm/trakrf-mosquitto/values.yaml -f helm/trakrf-mosquitto/values-gke.yaml --set hostname=h --set loadBalancerIP=1.2.3.4 >/dev/null && echo OK` → `OK`

---

### Task 2: WSS listener + `acl_file` + ACL ConfigMap key

**Files:**
- Modify: `helm/trakrf-mosquitto/templates/mosquitto-configmap.yaml`

- [ ] **Step 1: Add `acl_file` to the `:8883` listener block.** After its `password_file /mosquitto/auth/passwd` line (currently line 27), add:

```
    acl_file /mosquitto/config/acl
```

- [ ] **Step 2: Add the WSS listener block** immediately after the `:8883` block (after the new `acl_file` line, before the `# Stateless broker` comment):

```
    {{- if .Values.websocket.enabled }}

    # WebSocket (TLS) listener for the browser reader live-view (TRA-902).
    # mqtt.js over WSS. Same LE cert; TLS terminates here (LB is L4 passthrough).
    # Auth + ACL enforced — the frontend uses the read-only `frontend-readonly`
    # user (read trakrf.id/+/reads only). No anonymous.
    listener {{ .Values.websocket.port }} 0.0.0.0
    protocol websockets
    certfile /mosquitto/tls/tls.crt
    keyfile  /mosquitto/tls/tls.key
    tls_version tlsv1.2
    allow_anonymous false
    password_file /mosquitto/auth/passwd
    acl_file /mosquitto/config/acl
    {{- end }}
```

- [ ] **Step 3: Add the `acl` data key** to the ConfigMap, after the `mosquitto.conf` block (at the same indentation as `mosquitto.conf:` under `data:`):

```
  # Per-user ACL applied on the public listeners (:8883 + :8084). The loopback
  # :1883 listener has no acl_file, so the metrics exporter's $SYS reads are
  # unrestricted. trakrf-mqtt stays broad (backend subscriber + TRA-906 command
  # publisher + readers — unchanged); frontend-readonly is subscribe-only on the
  # read topics (cross-org by design; frontend filters client-side). TRA-857
  # tracks tighter per-user scoping.
  acl: |
    user trakrf-mqtt
    topic readwrite #

    user frontend-readonly
    topic read trakrf.id/+/reads
```

- [ ] **Step 4: Verify the render** —

Run:
```bash
helm template m helm/trakrf-mosquitto -f helm/trakrf-mosquitto/values.yaml -f helm/trakrf-mosquitto/values-gke.yaml --set hostname=h --set loadBalancerIP=1.2.3.4 --show-only templates/mosquitto-configmap.yaml | grep -nE 'listener 8084|protocol websockets|acl_file|^ +user |topic (readwrite|read)'
```
Expected: shows `listener 8084 0.0.0.0`, `protocol websockets`, two `acl_file /mosquitto/config/acl` lines (8883 + 8084), `user trakrf-mqtt`, `topic readwrite #`, `user frontend-readonly`, `topic read trakrf.id/+/reads`.

- [ ] **Step 5: Verify disabled path** — `helm template ... --set websocket.enabled=false --show-only templates/mosquitto-configmap.yaml | grep -c 'listener 8084'` → `0` (acl key + acl_file on 8883 still present; only the WSS listener is gated).

---

### Task 3: Container port

**Files:**
- Modify: `helm/trakrf-mosquitto/templates/deployment.yaml`

- [ ] **Step 1: Add the `wss` container port** to the mosquitto container `ports:` (after the `mqtts` port, ~line 41):

```yaml
            {{- if .Values.websocket.enabled }}
            - name: wss
              containerPort: {{ .Values.websocket.port }}
              protocol: TCP
            {{- end }}
```

- [ ] **Step 2: Verify** — `helm template ... --show-only templates/deployment.yaml | grep -A2 'name: wss'` → shows `containerPort: 8084`.

---

### Task 4: LoadBalancer port

**Files:**
- Modify: `helm/trakrf-mosquitto/templates/mqtt-service.yaml`

- [ ] **Step 1: Add the `wss` port** to the LoadBalancer `ports:` (after the `mqtts` port):

```yaml
    {{- if .Values.websocket.enabled }}
    - name: wss
      port: {{ .Values.websocket.port }}
      targetPort: wss
      protocol: TCP
    {{- end }}
```

- [ ] **Step 2: Verify** — `helm template ... --show-only templates/mqtt-service.yaml | grep -E 'name: (mqtts|wss)|port: (8883|8084)|targetPort'` → both `mqtts`/8883 and `wss`/8084 present.

---

### Task 5: `just mosquitto-secrets` — optional `frontend-readonly` user

**Files:**
- Modify: `justfile` (the `mosquitto-secrets` recipe, ~lines 156-191)

- [ ] **Step 1: Update the recipe header comment** to document the optional vars (after the `MOSQUITTO_PASSWORD` doc lines):

```
#   MOSQUITTO_FRONTEND_USER      (optional) read-only frontend user; default
#                                frontend-readonly. Subscribe-only on
#                                trakrf.id/+/reads (acl in the trakrf-mosquitto
#                                chart). Used by the TRA-902 browser reader feed.
#   MOSQUITTO_FRONTEND_PASSWORD  (optional) if set, a 2nd user is added to the
#                                password_file + literal creds to the Secret
#                                (frontend_username/frontend_password) for the
#                                public VITE bundle. Unset → skipped.
```

- [ ] **Step 2: Replace the passwd-hash + secret-create block** (current lines ~176-186) so it conditionally appends the second user and adds the frontend keys. New block:

```
    @# Use a throwaway eclipse-mosquitto container so we don't depend on a host
    @# mosquitto_passwd binary. Builds the hashed password_file (the shared user,
    @# plus an optional read-only frontend user when MOSQUITTO_FRONTEND_PASSWORD
    @# is set), then folds it into a Secret alongside the literal creds.
    @FRONTEND_USER="${MOSQUITTO_FRONTEND_USER:-frontend-readonly}"; \
     PASSWD_FILE=$(docker run --rm eclipse-mosquitto:2.0.21 sh -c \
      "mosquitto_passwd -b -c /tmp/passwd '${MOSQUITTO_USER}' '${MOSQUITTO_PASSWORD}' >/dev/null; \
       if [ -n '${MOSQUITTO_FRONTEND_PASSWORD:-}' ]; then mosquitto_passwd -b /tmp/passwd '${FRONTEND_USER}' '${MOSQUITTO_FRONTEND_PASSWORD}' >/dev/null; fi; \
       cat /tmp/passwd") && \
     kubectl create secret generic trakrf-mosquitto-auth -n trakrf-system \
       --from-literal=passwd="$PASSWD_FILE" \
       --from-literal=username="${MOSQUITTO_USER}" \
       --from-literal=password="${MOSQUITTO_PASSWORD}" \
       --from-literal=frontend_username="${FRONTEND_USER}" \
       --from-literal=frontend_password="${MOSQUITTO_FRONTEND_PASSWORD:-}" \
       --dry-run=client -o yaml | kubectl apply -f -
```

(Note: when `MOSQUITTO_FRONTEND_PASSWORD` is unset, `frontend_password` is an empty literal and no second user is hashed — inert, the `acl` entry references a user that can't auth.)

- [ ] **Step 3: Verify** the recipe parses — `just --evaluate >/dev/null 2>&1 && echo OK || just --summary | grep -c mosquitto-secrets` (recipe still listed). Visually confirm the heredoc/quoting is intact. (No docker run here — that's an operator action.)

---

### Task 6: Lint, full render sanity, commit

- [ ] **Step 1: `helm lint`** — `helm lint helm/trakrf-mosquitto` → `0 chart(s) failed`.

- [ ] **Step 2: Root-chart render** (ensure the per-env Application still templates) — `helm template root argocd/root -f argocd/root/values.yaml --set cluster=gke >/dev/null && echo OK` → `OK`.

- [ ] **Step 3: Confirm CI's `helm-mosquitto` job will pass** — re-run its exact command:
```bash
helm lint helm/trakrf-mosquitto -f helm/trakrf-mosquitto/values.yaml -f helm/trakrf-mosquitto/values-gke.yaml && \
helm template helm/trakrf-mosquitto -f helm/trakrf-mosquitto/values.yaml -f helm/trakrf-mosquitto/values-gke.yaml --set hostname=mqtt.preview.gke.trakrf.id --set loadBalancerIP=1.2.3.4 >/dev/null && echo CI-OK
```

- [ ] **Step 4: Commit** —
```bash
git add helm/trakrf-mosquitto justfile
git commit -m "feat(trakrf-mosquitto): WSS listener + read-only frontend ACL (TRA-902)"
```

---

## Post-merge verification (operator, not in-PR)

1. ArgoCD syncs → broker pod rolls (Recreate, brief gap). Confirm ingestion resumes: backend `subscribed`, `asset_scans` climbing (proves `trakrf-mqtt readwrite #` intact).
2. WSS reachable + browser-trusted: `openssl s_client -connect mqtt.preview.gke.trakrf.id:8084 -servername mqtt.preview.gke.trakrf.id </dev/null` → `Verify return code: 0`.
3. Activate the user: set `MOSQUITTO_FRONTEND_PASSWORD` in `.env.local`, run `just mosquitto-secrets` (Reloader bounces broker).
4. ACL test: `frontend-readonly` can `mosquitto_sub -t 'trakrf.id/+/reads'` but is denied publish / other topics.
5. Hand platform the wss URL + creds for the VITE env.

## Self-review

- **Spec coverage:** WSS listener (T1-T4 ✓), ACL incl. loopback-exempt (T2 ✓), frontend-readonly cred optional 2nd user (T5 ✓), rollout-safe inert-ACL ordering (post-merge notes ✓), verification (T6 + post-merge ✓). No gaps.
- **Placeholder scan:** none — every step has the literal YAML/config/command.
- **Consistency:** `websocket.enabled`/`websocket.port`, port name `wss`, `/mosquitto/config/acl`, user names `trakrf-mqtt`/`frontend-readonly`, secret keys `frontend_username`/`frontend_password` are consistent across tasks.
