# TRA-924 — Retire direct-browser MQTT: disable broker WSS + retire `frontend-readonly` (infra slice)

**Date:** 2026-06-04
**Ticket:** TRA-924 (Live Reads via backend SSE proxy, org-enforced — retire direct browser MQTT). Parent TRA-897. Reverses the infra half of TRA-902. Overlaps TRA-857 (broker ACLs), TRA-907 (multi-replica fan-out).
**Scope of this spec:** the **infra** slice only. The backend SSE endpoint (Go) and the frontend `useReaderFeed` → `EventSource` swap ship in the **platform** repo and are out of scope here. This spec covers retiring the now-unused broker WebSocket exposure and the `frontend-readonly` identity that TRA-902 introduced in `trakrf/infra`.

## Problem

TRA-902 wired a browser-direct MQTT path for the Live Reads tab: a public broker WSS listener (`:8084`) on the static-IP LoadBalancer, a least-privilege `frontend-readonly` broker user (ACL `read trakrf.id/+/reads`), and `READER_FEED_MQTT_*` env on the backend that stamps broker URL + subscribe-only creds into **pre-auth** `index.html`. Two customer-data leak vectors once real reads flow (from the ticket threat model):

1. **Cross-org leak via the UI** — the wildcard `trakrf.id/+/reads` has no org segment, so any owner/admin who opens Live Reads sees *every* org's reads. The browser can't be server-side org-filtered.
2. **Public broker + public creds (UI-independent)** — the WSS listener is public and the subscribe-only password lands in pre-auth HTML; **anyone** with those creds can pull all orgs' reads straight from the broker, no app involved.

TRA-924's agreed solution (option **b**) moves Live Reads to an authenticated, org-enforced backend **SSE** proxy that taps the in-process TRA-900 ingest stream. The browser never touches the broker again. That makes the entire TRA-902 browser-MQTT infra footprint dead — and, because of vector 2, leaving it live is a standing customer-data exposure. This spec retires it.

## Threat-model gate

Test/demo data exposure is acceptable; **customer** data exposure is not. This change must land **before any real customer reads are published to the broker**. Until then it is safe but not yet load-bearing. It is **not** a demo blocker (the demo/single-reader track is test data only).

## Decisions

- **Disable WSS via the existing `websocket.enabled` gate (set `false`), do not delete the chart machinery.** One gated flip removes the `:8084` listener, the container port, **and** the public LoadBalancer `wss` port together (all three are gated on `.Values.websocket.enabled`). After TRA-924 nothing connects to WSS at all — the browser is gone (SSE) and the in-backend ingester taps the parsed-read stream over the existing `:8883` MQTT path, not WSS. Keeping the (now-disabled) block as documented, gated config preserves cheap reversibility without carrying a live listener that has no consumer.
  - *Rejected — fully delete the WSS machinery:* cleanest end state but discards the TRA-902 capability; re-adding later means rewriting it. Not worth it for a one-line gate flip.
  - *Rejected — keep the listener live but cluster-internal (literal ticket wording):* would require decoupling the gate (listener stays, LB port goes) to keep a listener that has **zero** consumers. Strictly worse than off.
- **Retire the `frontend-readonly` broker identity.** Remove its ACL stanza from the broker config and remove its provisioning (`MOSQUITTO_FRONTEND_*` user + `frontend_username`/`frontend_password` secret keys) from `just mosquitto-secrets`. This closes vector 2 at the identity level: even if a WSS listener were ever re-exposed, the public subscribe-only creds no longer exist.
- **Remove the backend `readerFeed` runtime config.** Drop the `READER_FEED_MQTT_*` Deployment env block and `readerFeed` values from `helm/trakrf-backend`, and the `readerFeedEnabled` per-env flags + `readerFeed.url` inject from `argocd/root`. The browser receives no broker URL/creds via `window.__APP_CONFIG__.readerFeed` anymore.
- **No Tofu change.** The static LB IPs (`google_compute_address.mqtt_{preview,prod}`, TRA-828) stay — `:8883` still uses them. The public `:8084` exposure is purely the K8s `LoadBalancer` Service port, which disappears when WSS is gated off.

## Design

### 1. `helm/trakrf-mosquitto` — disable WSS, retire the ACL user

- `values.yaml`: `websocket.enabled: false` (was `true`). Comment updated to note WSS is retired by TRA-924 (browser moved to backend SSE); if ever re-enabled it would be a cluster-internal listener only — not re-exposed on the public LB without revisiting the threat model.
- `templates/mosquitto-configmap.yaml`:
  - The `{{- if .Values.websocket.enabled }}` WSS listener block stays (now inert). Its comment is updated: WSS retired by TRA-924; no `frontend-readonly` user exists anymore, so re-enabling would need a fresh ACL identity.
  - The `acl` block drops the `frontend-readonly` stanza. Only `trakrf-mqtt` (`readwrite #`) remains. The `:8883` listener keeps `acl_file`; behavior for `trakrf-mqtt` is unchanged.
- `templates/deployment.yaml` and `templates/mqtt-service.yaml`: no edits — the `wss` container port and the `wss` LoadBalancer port are already gated on `.Values.websocket.enabled` and vanish when it is `false`.

### 2. `justfile` — `mosquitto-secrets`

- Remove the optional `frontend-readonly` user from the `password_file` build (`MOSQUITTO_FRONTEND_USER`/`MOSQUITTO_FRONTEND_PASSWORD` branch) and the `frontend_username`/`frontend_password` literal keys from the Secret.
- Remove the corresponding doc block from the recipe header.
- Effect on live state: the **next** `just mosquitto-secrets` run regenerates `passwd` **without** `frontend-readonly` and drops the `frontend_*` Secret keys — retiring the broker user in-cluster. Until that run, the stale entries are inert (WSS is off; nothing authenticates as `frontend-readonly`). Noted in the PR as a post-merge runbook step.

### 3. `helm/trakrf-backend` — remove `readerFeed`

- `values.yaml`: delete the `readerFeed` block and its doc comment.
- `templates/deployment.yaml`: delete the `{{- if .Values.readerFeed.url }}` … `READER_FEED_MQTT_*` env block.

### 4. `argocd/root` — remove `readerFeedEnabled`

- `templates/trakrf-backend.yaml`: delete the `readerFeedEnabled` → `readerFeed.url` inject block + its comment.
- `values.yaml`: delete `readerFeedEnabled` from `preview` and `prod`, and the `readerFeedEnabled` doc comment.

## What this does NOT touch

- The `:8883` MQTT listener, the static LB IPs, the `trakrf-mqtt` user/ACL, the exporter loopback `:1883` — all unchanged. Fixed readers and the in-backend ingester keep connecting at `mqtt.<env>.gke.trakrf.id:8883`.
- The backend SSE endpoint and frontend `EventSource` swap (platform repo).
- Multi-replica fan-out (TRA-907): the in-process SSE tap is single-replica-safe; backend stays at 1 replica, unchanged here.

## Verification

- `helm lint` + `helm template` `helm/trakrf-mosquitto` (gke): renders **no** `:8084` listener, **no** `wss` container/LB port, and an `acl` block with only `trakrf-mqtt`.
- `helm lint` + `helm template` `helm/trakrf-backend` (default/gke): renders **no** `READER_FEED_MQTT_*` env.
- `helm template argocd/root` (gke): preview + prod backend Applications carry **no** `readerFeed` inline values; mosquitto Applications render with WSS off.
- `just --evaluate` / recipe parse: `mosquitto-secrets` still parses and builds a `passwd` with only `trakrf-mqtt`.

## Done when

- Broker WSS listener + public `:8084` LB exposure gone (gated off); `frontend-readonly` ACL stanza + provisioning retired.
- Backend `readerFeed` env + `readerFeedEnabled` flags removed; browser holds no broker creds.
- CI green (helm lint/template + root render).
- PR opened; **hold for approval before merge** (per request). Post-merge runbook: re-run `just mosquitto-secrets` to drop `frontend-readonly` from the live `passwd` + Secret.
