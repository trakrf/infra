# Production Cutover Runbook — TRA-375 / TRA-850

**Move TrakRF prod off Railway (backend/ingester) + TimescaleDB Cloud (DB) onto GKE + CNPG, and flip `app.trakrf.id` to the GKE origin (orange-cloud).**

- **Date:** 2026-05-30
- **Owners:** `infra` (Mike) — everything below except the image; `platform` — image rebuild + `:prod` promote
- **Status:** ✅ **EXECUTED + VERIFIED 2026-05-30** — `app.trakrf.id` live on GKE (orange), backend v1.2.0, all checks passed. The **As-run outcome** below is authoritative; the phased plan that follows is the as-written pre-execution record (kept for the trail + as a template for the next cutover).
- **Reference designs:** `docs/db-migration.md` (FDW mechanics), Linear TRA-375 / TRA-850 / TRA-888 / TRA-889

> This is the **real** customer-facing cutover. The dry-run (TRA-850) has been live and healthy on `app.prod.gke.trakrf.id` for 3 days. This runbook does the delta: durable deploy mechanism, real secret, fresh data, the public `app.trakrf.id` orange route, and the DNS flip.

---

## ✅ As-run outcome (executed + verified 2026-05-30)

Cutover **executed and verified end-to-end** — `app.trakrf.id` is live on GKE (orange-cloud), backend **v1.2.0**, data on dedicated `trakrf-db-prod` CNPG. Validated three ways: a real user write round-trip on the TrakRF org (edit → inventory → save → confirmed in history); platform's independent public-edge + global-uniqueness (TRA-886) checks; and infra's data/edge/origin-lock checks. UptimeRobot went green.

**What actually happened, with deviations from the plan below:**

- **Phase 0 — image:** platform **rebuilt** `main@8ca0955` → true v1.2.0 (digest `sha256:4fb6d0bb…`). A re-tag alone was insufficient — `git describe` bakes the version at build time, so the existing image self-reports `v1.1.1-165`. `:prod` was promoted to the v1.2.0 digest *before* the apply.
- **Phase 0 — secrets:** the dry-run `app.obfuscation_key` and `JWT_SECRET` were **kept** (verified valid; key distinct from preview's `6f6266…` test key) and archived to 1Password — no rotation (session continuity not required).
- **Phase 0 — edge cert (deviation):** the plan assumed grey / Universal SSL; instead we **pre-provisioned an ACM advanced cert** for `app.trakrf.id` (`acm-prod.tf`, active in 2m43s, PR #138) so the strict-SSL orange flip had no provisioning race.
- **Phase 2 ran BEFORE Phase 1 (deviation — to shrink the customer window):** `apply-root-app.sh gke` materialized the durable `trakrf-backend-prod` ImageUpdater CR → pinned `:prod`=`4fb6d0bb` in one shot → backend rolled to **v1.2.0**; pre-prod banner dropped; **JWT TTL→900** (v1.2.0 carries `/auth/refresh`). The public route host is an explicit per-env value **`appTrakrfIdHost`** (`app.trakrf.id`), NOT the derived `app.<env>.trakrf.id` — a render-check caught that deriving it yielded `app.prod.trakrf.id`. WAF challenge-skip extended to `app.trakrf.id`. DNS TTL pre-lowered 300→60. (PRs #139, #140.)
- **Phase 1 — data (deviation):** full from-scratch re-migration via the TRA-810 **natural-key FDW pull** (`backend/database/cutover/` files 00→20 @ platform `8ca0955`), run in-pod as `postgres`. **`asset_scans` WAS migrated** (16 rows — customers' current asset locations); only `tag_scans` left empty. Surrogate IDs re-minted (`RESTART IDENTITY`) → CNPG Feistel IDs ≠ TSC IDs. All verify gates passed; per-customer exact (NADA 17 assets/1 loc, Frederick Health 3 assets/1 loc). FDW torn down; `obfuscation_key` survived; backend bounced.
- **Phase 3 — DNS flip ⛔ (the one-way door):** `cloudflare_record.app` CNAME→A → `34.56.243.51` (`var.gke_traefik_lb_ip`), `proxied=true`. Verified: CF edge serves v1.2.0, propagated globally (1.1.1.1 + 8.8.8.8 → CF IPs), `/api` reachable, origin-lock direct-to-LB → **403**. (PR #141.)
- **Phase 4 — wind-down:** Railway prod deployment removed (config retained); **both TSC services paused** (not deleted); `pg_dump -Fc` of preview + prod pushed to GCS `tsc-final-archive/2026-05-30/` (non-expiring prefix — clear of the 14d lifecycle). Both envs confirmed reading from CNPG with TSC out of the loop. Linear TRA-351/375/850/888/889 closed; **TRA-893** tracks the post-soak teardown (delete TSC, remove Railway, drop `railway_*` vars). Memory updated.

**Net deviations from the as-written plan:** (1) ACM pre-provision, not grey/Universal SSL; (2) orange-cloud, not grey "mirror Railway"; (3) `asset_scans` migrated, not empty; (4) v1.2.0 required a fresh rebuild; (5) Phase 2 ran before Phase 1 to minimize downtime; (6) `appTrakrfIdHost` explicit-host fix; (7) `JWT_SECRET` kept, not Railway's.

---

## Plan (as written, pre-execution)

_The sections below are the runbook as authored before execution; where they differ, the As-run outcome above is authoritative._

## Decisions (locked with Mike, 2026-05-30)

| # | Decision | Choice |
|---|----------|--------|
| 1 | Scope today | **Full cutover to real users** |
| 2 | Data | **Full re-migration from scratch** — re-COPY current business tables from TSC; telemetry tables (`tag_scans`/`asset_scans`) start **empty** |
| 3 | `JWT_SECRET` | **Keep the existing value** already in `trakrf-prod` (valid 64-char random, set during the dry run). Session continuity not required, so no need to reuse Railway's or rotate. Archive to 1Password for recoverability. |
| 4 | DB HA | **Single-instance, HA deferred** (conscious; PITR is the safety net — see note on TRA-544) |
| 5 | Device/MQTT pipeline | **Out of scope** — no live fixed-reader workload; active customers are handheld-reader users on the web/API |
| 6 | Version | **v1.2.0 via rebuild** of `main@8ca0955` (platform-driven) |
| 7 | `app.trakrf.id` posture | **Orange-cloud** (CF-proxied, `cloudflare-allow` origin lock + CF Origin CA cert) — matches preview's TRA-856 pattern; closes TRA-375 item-7 origin-lock |

**HA-deferral rationale (record on TRA-544):** today's source is single-node TSC + single Railway instance, so single-instance CNPG is not an availability regression; it relocates an existing SPOF and *adds* tested WAL+PITR. RPO on catastrophic storage loss is bounded by WAL-archive interval (not zero); acceptable at current load (two occasional handheld users across two customers; ~1–2h RTO fine).

---

## Verified pre-cutover state (2026-05-30, against live `gke-trakrf-demo-usc1`)

- `trakrf-db-prod` CNPG Cluster: **Ready/healthy**, single instance (`trakrf-db-prod-1`), 25 MB total DB.
- `app.obfuscation_key`: **set** (64-hex, persists as a DB GUC across truncate/restore).
- Phase-1 (`pg_dump`) + Phase-2 (base backups + WAL) backups working; **DR drill executed 5/27** (drill base backup in GCS).
- Backend `Synced + Healthy`, currently on **`sha-24fc1b4`** (`3dd4b53d…`, the dry-run flatten image — **NOT** the cutover code; 2 merges behind `8ca0955`).
- `JWT_SECRET` populated with the **dry-run throwaway** (must be replaced with Railway's real value — Phase 0).
- Telemetry: `asset_scans` max ts `2026-05-23` (pre-migration), `tag_scans` empty → **CNPG holds no unique post-migration data**; re-migration loses nothing.
- CF Origin CA cert `trakrf-id-origin-tls` already reflected into `trakrf-prod` (orange origin-leg prereq met).
- `default-chain` = `security-headers` + `redirect-https` only (no IPAllowList); preview orange route serves real consumers via `default-chain` + `cloudflare-allow`. **No host-wide operator lockout** (TRA-856 already decoupled breakglass from the public route).
- Traefik LB IP: **`34.56.243.51`** (= `var.gke_traefik_lb_ip`, already used by `app.preview`).
- `cloudflare_record.app` (`app.trakrf.id`): currently `CNAME → var.railway_app_prod_endpoint`, `proxied=false`.

---

## Roles & handoff

- **platform:** rebuild `main@8ca0955` → true `v1.2.0` image; verify the build "Compute platform version" step reads `v1.2.0`; `promote-prod` re-tags `:prod` → that digest (imagetools, no rebuild). **Sends infra the v1.2.0 digest + version confirmation.**
- **infra (this runbook):** everything else. **Holds `apply-root-app.sh gke` until after platform promotes `:prod`** so the ImageUpdater CR pins the correct digest in one shot (no transient `24fc1b4` pin).

---

## Phase 0 — Pre-flight (fully reversible)

### 0.1 Image (platform-gated) — ✅ DONE 2026-05-30
- [x] platform confirms: rebuild green, build-step version = `v1.2.0`, `:prod` promoted → v1.2.0 digest.
- [x] **v1.2.0 digest (pinned target):** `sha256:4fb6d0bbf693c7271d122a1d41b8b64d28f3cbe322a1fe4e97990120743445e7`
  - `:prod` already resolves to this digest (promoted before our apply → ImageUpdater pins it in one shot).
  - **Reject** anything resolving to `f1559fad…` (v1.1.1-165) or `3dd4b53d…` (24fc1b4 dry-run).

### 0.2 Secrets — capture to 1Password (⚠️ blocker for `obfuscation_key`)
Session continuity is NOT required, so `JWT_SECRET` needs no rotation — both secrets are already valid on the cluster. The gap is **durable backup**: neither is stored outside the live cluster.

**Verified (2026-05-30):** prod `app.obfuscation_key` = real 64-hex random (fp `62107c0d84bd`, starts `a99e70`), distinct from preview, NOT the `6f6266…` test key. `JWT_SECRET` = 64 bytes, valid (TRA-860 guard passes).

- [ ] **`app.obfuscation_key` → 1Password (load-bearing — TRA-850 AC).** Lose it on a from-scratch rebuild and every existing user-facing ID becomes undecodable. Retrieve (run in a **plain terminal, not via the agent / not `!`**, so it never hits a transcript):
  ```bash
  kubectl -n trakrf-prod exec trakrf-db-prod-1 -- \
    psql -U postgres -d trakrf -At -c "SHOW app.obfuscation_key"
  ```
  1Password item (Infrastructure vault): **`trakrf-prod app.obfuscation_key`**, notes: *"Feistel cipher key for trakrf-db-prod. MUST re-apply via `ALTER DATABASE trakrf SET app.obfuscation_key=…` on any Cluster rebuild/restore or all IDs break."*
- [ ] **`JWT_SECRET` → 1Password (lower stakes — loss just forces re-login).**
  ```bash
  kubectl -n trakrf-prod get secret trakrf-backend -o jsonpath='{.data.JWT_SECRET}' | base64 -d; echo
  ```
  1Password item: **`trakrf-prod JWT_SECRET`**.
- [ ] Confirm both survive the v1.2.0 roll: chart omits `JWT_SECRET` when placeholder; `ignoreDifferences` carve-out protects `/data/JWT_SECRET`; `obfuscation_key` is a DB GUC (persists across pod rolls + basebackups).

### 0.3 Cloudflare edge readiness (for the orange flip) — ⚠️ verify before Phase 3
**Finding (2026-05-30):** CF serves **per-hostname** edge certs in this zone (e.g. `docs.trakrf.id` → GTS cert, SAN `docs.trakrf.id` only — NOT a `*.trakrf.id` wildcard). `app.trakrf.id` is still grey and presents **Railway's** LE cert, so CF likely has **no edge cert for `app.trakrf.id` yet**. Zone is `ssl=strict`, so flipping `proxied=true` with no active edge cert → TLS errors for real users.

- [x] **Chose (a) ACM pre-provision** (matches preview). `cloudflare_certificate_pack.prod_app_advanced` for `app.trakrf.id` — **created + ACTIVE 2026-05-30** (id `54b8ada0-3789-40c6-8040-166c1853c125`, `wait_for_active_status` passed in 2m43s). Applied from branch `feat/tra-375-prod-cutover` → **PR must merge to reconcile `main` with live state** (else a `main`-side `just cloudflare` would destroy the pack).
- [ ] Confirm **Bot Fight Mode** posture won't challenge `/api/v1/*` (CF dashboard) — mirror the preview WAF skip (Phase 2.3).
- [ ] (At flip time) re-confirm the edge cert serves on `app.trakrf.id` once proxied.

### 0.4 Source snapshot
- [ ] Snapshot current TSC prod row counts for the post-migration diff:
  ```bash
  psql "$TSC_PROD_DSN" -At -F $'\t' -c "
    SELECT schemaname||'.'||relname, n_live_tup FROM pg_stat_user_tables
    WHERE schemaname IN ('public','trakrf') ORDER BY 1" > /tmp/tsc-prod-pre.tsv
  ```

---

## Phase 1 — Final data re-migration from TSC (reversible)

Brief maintenance window (Mike approved). Data is 25 MB → seconds of actual movement; downtime is choreography-bound.

- [ ] **Freeze:** scale Railway prod backend to 0 (stop writes to TSC) so TSC is a stable source. Post maintenance notice if desired.
- [ ] **Truncate** business tables in `trakrf-db-prod` (leave `tag_scans`/`asset_scans` empty, preserve schema + `schema_migrations` + `app.obfuscation_key`). Order by FK or `TRUNCATE ... CASCADE`.
- [ ] **Re-COPY** current business data via the FDW path — follow `docs/db-migration.md` with prod substitutions (`<env>=prod`, `<ns>=trakrf-prod`, `<cluster>=trakrf-db-prod`, source = TSC prod DSN). Run from inside `trakrf-db-prod-1` (FDW reaches out to TSC; no inbound LB needed). Bracket any hypertable with `timescaledb_pre_restore()`/`_post_restore()` (telemetry tables stay empty, so likely N/A).
- [ ] **Row-count diff** vs `/tmp/tsc-prod-pre.tsv` (telemetry rows expected to differ — they're intentionally empty).
- [ ] **Tear down FDW** (`DROP SERVER … CASCADE`; verify `pg_foreign_server` empty).
- [ ] Verify `SHOW app.obfuscation_key` still 64-hex; `kubectl -n trakrf-prod rollout restart deploy/trakrf-backend` so connections re-read the GUC.

---

## Phase 2 — Deploy mechanism + values + orange route (infra PR; reversible)

**Runs after platform has promoted `:prod` → v1.2.0 digest.**

Work on a fresh worktree/branch off latest `origin/main` (current local `main` is stale). Per CLAUDE.md: PR, **never merge locally**.

### Code changes
- [ ] `argocd/root/values.yaml` — `envs.prod`: `environmentLabel: "GKE pre-prod"` → `""` (drop the pre-prod banner). **Leave `jwtExpirationSeconds: "3600"` for now** (flips in 2.6, after v1.2.0 is confirmed live).
- [ ] `argocd/root/templates/trakrf-backend.yaml` — enable the orange `app.trakrf.id` route for prod: change the call-site gate `"appTrakrfIdRouteEnabled" (eq $env "preview")` to also cover prod (`(or (eq $env "preview") (eq $env "prod"))`, or `true` since both envs now want it). This emits the existing orange route shape (`default-chain` + `cloudflare-allow`, `trakrf-id-origin-tls`, `cert.issue:false`) — Origin CA cert already in `trakrf-prod`.
- [ ] `terraform/cloudflare/trakrf-id-waf.tf` — add an `app.trakrf.id` non-interactive WAF skip mirroring the `app.preview.trakrf.id` rule (`/api/*` + `/openapi.*`).
- [ ] Render check: `helm template root argocd/root --set cluster=gke …` — confirm **preview output unchanged** (apply-root-app is cluster-wide) and prod gains the `trakrf-id-direct` route + ImageUpdater CR annotations.
- [ ] PR → review → `gh pr merge --merge`.

### Apply (NOT the DNS record yet)
- [ ] CF WAF rule only — apply the ruleset target without touching the `app` record:
  ```bash
  tofu -chdir=terraform/cloudflare apply -target=<app.trakrf.id WAF ruleset resource>
  ```
- [ ] `git checkout main && git pull` then materialize the durable deploy mechanism + values:
  ```bash
  ./scripts/apply-root-app.sh gke
  ```
  This applies prod `environmentLabel=""`, enables the orange route, and **materializes the `trakrf-backend-prod` ImageUpdater CR** → pins the v1.2.0 `:prod` digest → backend rolls to **v1.2.0**.

### Verify (pre-flip)
- [ ] Backend pods on the **v1.2.0 digest**, `Running`, `Synced + Healthy`.
- [ ] `/health.json` on the grey direct route reads **`v1.2.0`**:
  ```bash
  curl -sf --resolve app.prod.gke.trakrf.id:443:34.56.243.51 https://app.prod.gke.trakrf.id/health.json
  ```
- [ ] `trakrf-backend-prod` ImageUpdater CR present + `READY`, pinning the v1.2.0 digest (not `f1559fad` / `3dd4b53d`).
- [ ] `app.trakrf.id` IngressRoute exists with `trakrf-id-origin-tls` + `cloudflare-allow` (dormant — DNS still → Railway, so it receives no traffic yet).
- [ ] Pre-prod banner gone from `index.html`.

### 2.6 Flip JWT TTL → 900 (now that v1.2.0 is live)
- [ ] Confirm `/auth/refresh` works on the live v1.2.0 prod image (token refresh returns `expires_in=900` on a test login via the direct route).
- [ ] `argocd/root/values.yaml` — `envs.prod.jwtExpirationSeconds: "3600"` → `"900"`; PR/merge; `./scripts/apply-root-app.sh gke`; verify backend rolls and refresh holds. (Users arrive post-flip already on 900 + working refresh.)

---

## Phase 3 — DNS flip ⛔ ONE-WAY DOOR

**GATE: explicit Mike go-ahead before this step.**

### Pre-flip checklist
- [ ] v1.2.0 live on prod; `/health.json=v1.2.0`; `/auth/refresh` working; JWT=900.
- [ ] Business data re-migrated + verified; `obfuscation_key` set.
- [ ] Orange route dormant-ready; CF Universal SSL edge cert active for `app.trakrf.id`; WAF skip in place.
- [ ] Real `JWT_SECRET` in place (sessions will validate).
- [ ] **Railway prod still up** (rollback target) — do not decommission until soak passes.

### Flip
- [ ] `terraform/cloudflare/main.tf` — `cloudflare_record.app`: `type: CNAME → A`, `content: var.railway_app_prod_endpoint → var.gke_traefik_lb_ip`, `proxied: false → true`. Apply *only* this record to control the door:
  ```bash
  tofu -chdir=terraform/cloudflare apply -target=cloudflare_record.app
  ```
  (Apply-order is safe: `cloudflare-allow` is already on the route while DNS still points at Railway, so flipping straight to `proxied=true` never exposes a grey origin to a 403 window.)

### Verify (real users now on GKE)
- [ ] `dig app.trakrf.id` → Cloudflare proxy IPs (orange).
- [ ] `curl -sf https://app.trakrf.id/health.json` → 200 + `v1.2.0` (through the CF edge).
- [ ] `curl -sf https://app.trakrf.id/api/v1/<health>` from a non-operator network → 200 (confirms **no** host-wide IP lockout; cloudflare-allow permits CF-proxied traffic).
- [ ] Browser login round-trip on `https://app.trakrf.id` (validates `JWT_SECRET` continuity + `obfuscation_key` Feistel path).
- [ ] A real handheld-reader workflow end-to-end.
- [ ] Origin lock holds: direct hit to `34.56.243.51` with `Host: app.trakrf.id` (bypassing CF) → refused by `cloudflare-allow`.

### Rollback (if verification fails)
- [ ] Revert `cloudflare_record.app` to `CNAME → var.railway_app_prod_endpoint`, `proxied=false`; `tofu apply -target=cloudflare_record.app`. Railway serves again within DNS TTL. **Risk window:** any GKE-side writes between flip and rollback are lost (acceptable at current load; keep the window short).

---

## Phase 4 — Soak + decommission

- [ ] **Soak** (hours → a day): watch error rates, latency histograms (TRA-494), `/auth/refresh` metrics, ingester idle-but-healthy, CNPG backups still firing. Direct kubectl/Grafana checks at the upper bound of the window (don't trust silent monitors).
- [ ] **Decommission Railway prod:** archive the service; remove `var.railway_app_prod_endpoint` + any now-dead references in `terraform/cloudflare`.
- [ ] **Decommission TSC prod:** take a final logical dump for cold archive, then stop the instance.
- [ ] **Linear:** close TRA-850 ACs (Cluster live, key set, data cut over, PITR/DR drill done, shared cluster retired, DR drill passes); close TRA-888 (durable digest-pin live) + TRA-889 (real secret injected); update TRA-375 (epic progress); add the HA-deferral note to TRA-544.
- [ ] **Memory:** update `project_prod_cutover_schedule`, `feedback_prod_prod_tag_ifnotpresent_gap`, and add a cutover-outcome note.

---

## One-way-door summary

The only irreversible-ish step is **Phase 3 DNS flip**, and even that rolls back by reverting the record (Railway stays warm through soak). Everything in Phases 0–2 is reversible. Hard gates: **(a)** platform's v1.2.0 digest before any deploy-mechanism apply; **(b)** v1.2.0 confirmed live before JWT→900; **(c)** explicit Mike go-ahead before the DNS flip.
