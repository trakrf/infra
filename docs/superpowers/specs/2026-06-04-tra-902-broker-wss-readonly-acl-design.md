# TRA-902 — Broker WebSocket (WSS) listener + read-only ACL for the frontend reader live-view

**Date:** 2026-06-04
**Ticket:** TRA-902 (browser reader live-view / coverage diagnostic — frontend subscribes to MQTT directly via mqtt.js over WebSocket). Overlaps TRA-857 (broker ACLs). Builds on TRA-907 (`helm/trakrf-mosquitto`).
**Scope of this spec:** the **infra** prerequisites — the two broker-side pieces the frontend feature needs to activate. The frontend (platform repo) ships disabled (`VITE_READER_FEED_MQTT_URL` empty) and is out of scope here.

## Problem

The frontend wants a live tag-read view by subscribing to the broker directly from the browser (mqtt.js over WSS, like Power Mixer did against EMQX cloud). The current `trakrf-mosquitto` broker:
1. Exposes **only native MQTT** — TLS `:8883` + loopback `:1883` (exporter). No WebSocket listener → browsers can't connect.
2. Has **no topic ACL** — a single shared `trakrf-mqtt` user (auth-only). The frontend's MQTT creds are baked into a **public** VITE bundle, so it must NOT use the ingester's full-access creds; it needs a least-privilege, subscribe-only identity.

## Decisions (from brainstorming)

- **Dedicated read-only user** (`frontend-readonly`), ACL-scoped to `read trakrf.id/+/reads`. Creds are public-in-bundle but low-value (subscribe-only). (vs. anonymous-read on the WS listener — rejected: introduces an anonymous-allowed listener on a public broker, less revocable.)
- **Cross-org reads accepted** for this diagnostic feature: `trakrf.id/{external_key}/reads` has no org dimension, so `frontend-readonly` can read all orgs' reads. The frontend filters client-side; the page is admin-gated. Documented as a known limitation; true per-org isolation (org segment in the topic, or dynamic per-org ACLs) is separate/later work (overlaps TRA-857).

## Design

### 1. WSS listener (`helm/trakrf-mosquitto`)

Gated on a new value `websocket.enabled: true` (default on; both envs — additive and auth-protected). In `mosquitto-configmap.yaml`, after the `:8883` block:

```
# WebSocket (TLS) listener for the browser reader live-view (TRA-902).
# mqtt.js over WSS. Reuses the LE cert; TLS terminates at mosquitto (the LB is
# L4 passthrough). Auth + ACL enforced (no anonymous).
listener {{ .Values.websocket.port }} 0.0.0.0
protocol websockets
certfile /mosquitto/tls/tls.crt
keyfile  /mosquitto/tls/tls.key
tls_version tlsv1.2
allow_anonymous false
password_file /mosquitto/auth/passwd
acl_file /mosquitto/config/acl
```

- `deployment.yaml`: add container port `wss` = `{{ .Values.websocket.port }}` (8084).
- `mqtt-service.yaml`: add a `wss` port (8084) to the existing static-IP `LoadBalancer` (same IP, passthrough).
- Client URL: `wss://mqtt.<env>.gke.trakrf.id:8084/mqtt` (path is client-determined; mosquitto serves the WS upgrade regardless of path). TLS 1.2; cert is the existing browser-trusted Let's Encrypt cert (`trakrf-mqtt-tls`).

### 2. ACL (`acl_file`)

New `acl` data key in the config ConfigMap → mounted at `/mosquitto/config/acl`. Applied **per-listener** (the config uses `per_listener_settings true`) via `acl_file /mosquitto/config/acl` in the `:8883` and `:8084` listener blocks **only**. The loopback `:1883` block gets **no** `acl_file`, so the metrics exporter's `$SYS` reads stay unrestricted (internal-only listener).

```
# trakrf-mqtt — the backend subscriber (trakrf.id/+/reads), the TRA-906 alarm
# command publisher (e.g. shelly1g4-.../command/...), and the readers. Broad on
# the public listeners; the metrics exporter uses loopback :1883 (no acl_file)
# so its $SYS reads are unaffected. Tighter per-user scoping is TRA-857.
user trakrf-mqtt
topic readwrite #

# frontend-readonly — browser reader live-view (TRA-902). Subscribe-only on the
# read topics. Cross-org by design (reads topic has no org segment); the frontend
# filters client-side. Creds are public in the VITE bundle → least-privilege.
user frontend-readonly
topic read trakrf.id/+/reads
```

Keeping `trakrf-mqtt` `readwrite #` is deliberate — `#` covers `trakrf.id/+/reads` (backend) and the Shelly command topics (TRA-906), so **no current behavior changes**. (`#` excludes `$SYS` by MQTT convention, which `trakrf-mqtt` doesn't need on the public listeners.)

### 3. `frontend-readonly` credential (`just mosquitto-secrets`)

Extend the recipe with an **optional** second user:
- Read `MOSQUITTO_FRONTEND_USER` (default `frontend-readonly`) + `MOSQUITTO_FRONTEND_PASSWORD` from `.env.local`.
- **If `MOSQUITTO_FRONTEND_PASSWORD` is unset → skip** (recipe unchanged for envs not using the feature).
- If set → append the user to the `passwd` file (`mosquitto_passwd -b` without `-c`), and add `frontend_username` + `frontend_password` literal keys to the `trakrf-mosquitto-auth` secret (for retrieval/delivery; existing consumers only read `passwd`/`username`/`password`, so the new keys are inert to them). The secret is Reflector-mirrored to `trakrf-preview`/`trakrf-prod` as today.
- Operator supplies the password in `.env.local` and hands the cleartext to platform for the VITE env.

## Rollout & safety

- The chart change syncs via ArgoCD; the broker uses `strategy: Recreate`, so the pod rolls with a **brief ingestion gap** (readers + backend reconnect — same as prior broker rolls). Acceptable.
- **Ordering is safe:** the `acl_file` references `frontend-readonly` before it exists in `passwd` — that's inert (no such user can auth), and `trakrf-mqtt` is unaffected. So the chart can merge/deploy first; the user is activated later by a `just mosquitto-secrets` run once `MOSQUITTO_FRONTEND_PASSWORD` is set.
- The ACL is a live-auth change — `trakrf-mqtt` stays `readwrite #` precisely so the backend subscriber, TRA-906 publisher, and exporter keep working.

## Verification

- **In-PR:** `helm lint` + `helm template` — WSS listener renders with the values, `acl` ConfigMap key present + mounted at `/mosquitto/config/acl`, `:8084` on the LoadBalancer + container port, `acl_file` on `:8883`/`:8084` but not `:1883`.
- **Post-deploy (on merge):** (a) ingestion continues — backend still `subscribed`, `asset_scans` climbing (confirms `trakrf-mqtt readwrite #` intact); (b) `:8084` WSS reachable from outside with a browser-trusted cert (openssl/ws probe to `mqtt.preview.gke.trakrf.id:8084`); (c) after activating `frontend-readonly`, it can SUBSCRIBE `trakrf.id/+/reads` but is denied publish and other topics (ACL test via mosquitto_sub/pub).

## Known limitation

`frontend-readonly` reads **all orgs'** reads (`trakrf.id/+/reads` is not org-partitioned). The frontend filters client-side. Per-org isolation needs an org dimension in the reads topic (platform) or dynamic per-org users/ACLs (infra) — out of scope; revisit with TRA-857.

## Activation handoff (post-merge, when prioritized)

1. Set `MOSQUITTO_FRONTEND_PASSWORD` (+ optional `MOSQUITTO_FRONTEND_USER`) in `.env.local`; run `just mosquitto-secrets` (Reloader bounces the broker).
2. Give platform: `wss://mqtt.<env>.gke.trakrf.id:8084/mqtt`, user `frontend-readonly`, the password, topic `trakrf.id/+/reads` → they set the VITE env on preview to validate end-to-end.

## Out of scope

- The frontend feature itself (platform repo, ships disabled).
- Tightening `trakrf-mqtt`'s ACL / full per-user lockdown (TRA-857).
- Per-org read isolation.
