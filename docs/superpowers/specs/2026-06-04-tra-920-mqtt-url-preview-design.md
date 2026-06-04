# TRA-920 — Enable live MQTT ingestion on preview (infra: `MQTT_URL` wiring)

**Date:** 2026-06-04
**Ticket:** TRA-920 (parent TRA-897); related TRA-900 (subscriber, merged `c775c94`), TRA-899 (scan_devices/points), TRA-907 (decommission RC ingester)
**Scope of this spec:** **Task 1 only** — the infra-repo (`trakrf/infra`) change that sets `MQTT_URL` (+ `MQTT_TOPIC`, `MQTT_CLIENT_ID`) on the **preview** `trakrf-backend` deployment so the in-backend Go MQTT subscriber starts.

Tasks 2–3 (app-side `scan_devices`/`scan_points` + `rfid` tag registration on Organized Chaos) and Task 4 (live end-to-end smoke) are owned by the **platform** agent and are **already complete on the data side** (org `420930187320223`, migration `000012` applied, `resolve_scan_topic` routing all 3 live topics). They are out of scope for this PR; this spec documents the verification handoff.

## Problem

The TRA-900 subscriber (`internal/cmd/serve/serve.go`) starts **only when `MQTT_URL` is non-empty**, and is inert otherwise. The preview backend currently has **no `MQTT_*` env set**, so nothing ingests. We need to wire `MQTT_URL` into the preview backend deployment, sourced so that **no plaintext broker credentials land in git**.

### Why the wiring is conditional (and why it's *not* heavy "safety" gating)

The chart serves preview, prod, AKS, and EKS. Setting `MQTT_URL` only where ingestion is wanted is the correct shape, but it is **not** load-bearing safety — three independent factors already make other envs inert:

1. **Old code** — prod (`:prod` = `sha-c372f81`) and AKS/EKS (on ice) run pre-TRA-900 images that ignore `MQTT_URL` entirely.
2. **No traffic** — physical readers only publish to the preview broker (`mqtt.preview.gke.trakrf.id`).
3. **No registry** — no `scan_devices`/`publish_topics` exist in other envs, so the tag-membership filter would drop everything regardless.

So the only conditional we add is the mundane one: the deployment template renders the MQTT env block **when a broker host is configured**, and we configure it for **preview only**. Prod is left off because the ticket scopes prod to a later cutover — not for safety — and leaving it as a one-line flag flip is the cleanest cutover ergonomics.

## Design

Mirror the **existing `trakrf-ingester` pattern** (`helm/trakrf-ingester`), which already composes `MQTT_URL` via Kubernetes `$(VAR)` env interpolation from the `trakrf-mosquitto-auth` secret. Key difference: the ingester reaches Mosquitto over **loopback** (`mqtt://…@localhost:1883`, broker is a sidecar in the same pod); the backend is a **separate pod**, so it reaches the broker over its **public LB hostname with TLS** (`mqtts://…@mqtt.preview.gke.trakrf.id:8883`), matching the cert SAN.

Enable signal: **the broker host being non-empty** is the in-chart trigger (no separate boolean in the chart). Per-env selection lives in the root chart via a new `mqttEnabled` flag.

### Change 1 — `helm/trakrf-backend/values.yaml`

Add an `mqtt:` block, **off by default** (empty `host`):

```yaml
# MQTT ingestion (TRA-920 / TRA-900). The in-backend Go subscriber starts
# only when MQTT_URL is non-empty (serve.go gate). Empty host here = no MQTT
# env rendered = subscriber inert. Preview turns this on via the root chart
# inlineValues (argocd/root/templates/trakrf-backend.yaml); prod/AKS/EKS stay
# off. Credentials come from the broker auth Secret (trakrf-mosquitto-auth,
# Reflector-mirrored into the env namespace) and are composed into MQTT_URL
# via $(VAR) interpolation — no creds in git.
# See feedback_k8s_dsn_composition + feedback_mqtt_clientid_per_cluster.
#
# NOTE: keep the backend at 1 replica (replicaCount: 1, autoscaling.enabled:
# false) while MQTT is on. Non-shared subscriptions fan out every message to
# every connected client, so multiple replicas double-write asset_scans until
# $share/... shared subscriptions land (TRA-907).
mqtt:
  # Broker LB hostname. Empty = MQTT disabled. Set per-env by the root chart.
  host: ""
  port: 8883
  # mqtts (TLS): backend is a separate pod from the broker, reaching it over
  # the public LB hostname (Let's Encrypt cert SAN), not the ingester loopback.
  scheme: mqtts
  # trakrf.id/# is correct for single-replica preview. Switch to a $share/...
  # group topic when multi-replica lands (TRA-907).
  topic: "trakrf.id/#"
  # Distinct base clientId (overridden per-env by the root chart). Must differ
  # from the RC ingester's clientId so the broker doesn't evict one while both
  # are connected. The subscriber also appends the pod hostname at runtime.
  clientId: trakrf-backend
  # Broker auth Secret (username/password keys). Created by `just
  # mosquitto-secrets`, mirrored into the env namespace by Reflector.
  authSecret: trakrf-mosquitto-auth
```

### Change 2 — `helm/trakrf-backend/templates/deployment.yaml`

Add a conditional MQTT env block to the container `env:` list, **after** `PG_URL`. Order matters: `MQTT_USER`/`MQTT_PASSWORD` must precede `MQTT_URL` so `$(VAR)` interpolation resolves.

```yaml
            {{- if .Values.mqtt.host }}
            # MQTT ingestion subscriber (TRA-920). MQTT_URL composed via $(VAR)
            # interpolation from the broker auth Secret — no creds in git.
            # See feedback_k8s_dsn_composition.
            - name: MQTT_USER
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.mqtt.authSecret }}
                  key: username
            - name: MQTT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.mqtt.authSecret }}
                  key: password
            - name: MQTT_URL
              value: "{{ .Values.mqtt.scheme }}://$(MQTT_USER):$(MQTT_PASSWORD)@{{ .Values.mqtt.host }}:{{ .Values.mqtt.port }}"
            - name: MQTT_TOPIC
              value: {{ .Values.mqtt.topic | quote }}
            - name: MQTT_CLIENT_ID
              value: {{ .Values.mqtt.clientId | quote }}
            {{- end }}
```

### Change 3 — `argocd/root/values.yaml`

Add a per-env `mqttEnabled` flag (documented alongside the other `envs.*` fields):

```yaml
envs:
  preview:
    # ...existing...
    mqttEnabled: true   # TRA-920: live ingestion on preview
  prod:
    # ...existing...
    mqttEnabled: false  # flip to true at prod cutover (see checklist)
```

### Change 4 — `argocd/root/templates/trakrf-backend.yaml`

Inject the per-env MQTT inlineValues when `mqttEnabled`, appended to `$base` (mirrors the existing `imageTag` conditional and the ingester's broker-host injection):

```yaml
{{- if $cfg.mqttEnabled }}
{{- $base = printf "%smqtt:\n  host: mqtt.%s.gke.trakrf.id\n  clientId: trakrf-backend-%s-%s\n" $base $env $.Values.cluster $env }}
{{- end }}
```

Renders for preview: `host: mqtt.preview.gke.trakrf.id`, `clientId: trakrf-backend-gke-preview`. `port`/`scheme`/`topic`/`authSecret` come from chart defaults.

## What we deliberately do NOT change

- **Replica count** — `replicaCount: 1` + `autoscaling.enabled: false` already hold preview at 1; no change. Documented in the values comment so it isn't accidentally bumped while MQTT is on.
- **Secret provisioning** — reuse the existing `trakrf-mosquitto-auth` (already created + Reflector-mirrored for the ingester); no new ExternalSecret/kubectl step.
- **AKS/EKS overlays** — empty `mqtt.host` default keeps them inert; no edits.
- **No cluster guard on the injection** — `mqtt.<env>.gke.trakrf.id` is GKE-specific, but per the three-factor argument above an accidentally-enabled non-GKE env is inert (old image, no readers, no registry). Documented as a latent cross-cloud caveat rather than guarded, to avoid speculative complexity for on-ice clusters. Revisit if AKS/EKS are revived with current images.

## Verification (pre-merge, in-PR)

- `helm template` the chart with preview-equivalent values and confirm: MQTT env block renders, `MQTT_USER`/`MQTT_PASSWORD` precede `MQTT_URL`, `MQTT_URL = mqtts://$(MQTT_USER):$(MQTT_PASSWORD)@mqtt.preview.gke.trakrf.id:8883`, `MQTT_TOPIC=trakrf.id/#`, `MQTT_CLIENT_ID=trakrf-backend-gke-preview`.
- `helm template` with default/prod values and confirm **no** MQTT env block renders.
- Render the root chart (`cluster: gke`) and confirm the preview backend Application's inlineValues carry the `mqtt:` block and the prod one does not.

## Verification (post-merge, post-sync — handoff to platform)

After merge + ArgoCD sync (root-chart edit also needs `scripts/apply-root-app.sh gke` to re-render the child apps — see `feedback_root_chart_needs_manual_bump` / `feedback_apply_root_app_cluster_wide`):

1. Preview backend pod restarts with `MQTT_*` set; logs `mqtt subscriber connecting` → `subscribed`.
2. Broker ACL allows the `trakrf-mosquitto-auth` user to SUBSCRIBE on `trakrf.id/#` (RC used the same creds as a subscriber, so expected to pass).
3. `asset_scans` populate for Organized Chaos from live `cs463-212` / `cs463-214` traffic.
4. `/metrics`: `ingest_messages_total{result="received"}` and `ingest_asset_scans_inserted_total` advance; `ingest_reads_dropped_total{reason="no_asset"}` ~0 for registered EPCs.

Platform agent runs this smoke; this PR pings them once the pod is up with `subscribed`.

## Prod enablement checklist (future cutover — stretch in ticket)

1. Prod broker `mqtt.prod.gke.trakrf.id:8883` up, cert valid, ACL allows the auth user to SUBSCRIBE.
2. `trakrf-mosquitto-auth` Reflector-mirrored into `trakrf-prod` ns.
3. App-side: prod org has `scan_devices`/`publish_topics` + `rfid` tags for live EPCs (mirror of preview Tasks 2–3).
4. Prod readers actually publishing to the prod broker.
5. Prod backend image includes the TRA-900 subscriber (image lineage check, not just version string).
6. Prod stays at **1 replica** (no autoscaling) until `$share` shared-subscriptions land.
7. Flip `envs.prod.mqttEnabled: true` in `argocd/root/values.yaml`; merge PR.
8. **Re-run `scripts/apply-root-app.sh gke`** — root-chart edits don't auto-sync.
9. Verify prod pod logs `subscribed` + `ingest_*` counters advance + `asset_scans` land in the prod org.

## Immediate follow-up

**TRA-907 — decommission the Redpanda Connect ingester.** Once preview ingestion is green end-to-end, retire RC promptly: while both RC and the new subscriber are connected they both consume the broker. Today RC's `tag_scans` inserts are inert (migration `000012` dropped the `process_tag_scans` fan-out trigger), so `asset_scans` is single-writer — but RC is still pulling traffic and writing orphan `tag_scans` rows, and the overlap is exactly the double-write hazard TRA-907 exists to remove.
