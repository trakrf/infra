# Edge Demo Cloudflare Tunnel — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose the edge demo app at `https://app.demo.trakrf.id` from any network via a Terraform-managed Cloudflare Tunnel, with a box-side `cloudflared` connector and hands-free LE cert renewal.

**Architecture:** `trakrf/infra` Terraform defines the tunnel, remotely-managed ingress (`app.demo.trakrf.id → https://traefik:443`, box-local leg `no_tls_verify`), and a proxied CNAME replacing the stale private A record. The box (`trakrf-demo`, this host) runs a rootless-podman `cloudflared` quadlet using a TF-minted token, plus a systemd-user timer that opportunistically renews the LE cert via DNS-01 whenever the uplink is up.

**Tech Stack:** OpenTofu + Cloudflare provider v4.52.7, `hashicorp/random`; rootless podman quadlets; systemd user units; `goacme/lego` (DNS-01).

**Spec:** `docs/superpowers/specs/2026-06-08-tra-957-cloudflare-tunnel-edge-demo-design.md`

**Repos / branches:**
- Phase A — `trakrf/infra`, branch `miks2u/tra-957-expose-edge-demo-app-publicly-via-cloudflare-tunnel` (already created, working dir `/home/mike/infra`).
- Phase B — `trakrf/platform`, new branch `feat/tra-957-cloudflared-edge-tunnel` (working dir `/home/mike/platform`, the **live** checkout — quadlets symlink to `%h/platform/deploy/edge`).

**Resolved constants (verified 2026-06-08):**
- cloudflared image: `docker.io/cloudflare/cloudflared:2026.5.2` (tag confirmed pullable).
- Linger: already enabled for `mike` (`loginctl show-user mike` → `Linger=yes`).
- Infra CF API token env var: `CLOUDFLARE_API_TOKEN` (in `/home/mike/infra/.env.local`, provider + REST).
- Zone: `trakrf.id`; account `var.account_id`. Tunnel name: `trakrf-demo-edge`.

---

## Phase A — Infra (Terraform)

### Task A1: Add the `random` provider

**Files:**
- Modify: `terraform/cloudflare/versions.tf`

- [ ] **Step 1: Add `hashicorp/random` to `required_providers`**

In `terraform/cloudflare/versions.tf`, add the `random` block alongside `cloudflare` and `tls`:

```hcl
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
```

- [ ] **Step 2: Fetch the provider and update the lock**

```bash
cd /home/mike/infra
just _backend-conf terraform/cloudflare   # regenerate backend.conf (idempotent; path is relative to -chdir)
tofu -chdir=terraform/cloudflare init -upgrade -backend-config=backend.conf
```
Expected: `Installing hashicorp/random …` and `.terraform.lock.hcl` updated to include `hashicorp/random`.

> Note: `init` needs the R2 backend env (`CLOUDFLARE_*`) loaded from `.env.local`. If direnv isn't active in the shell, run `set -a; . /home/mike/infra/.env.local; set +a` first.

---

### Task A2: Write the tunnel resources

**Files:**
- Create: `terraform/cloudflare/demo-tunnel.tf`

- [ ] **Step 1: Create `terraform/cloudflare/demo-tunnel.tf`**

```hcl
# app.demo.trakrf.id — edge demo box exposed publicly via Cloudflare Tunnel (TRA-957).
# cloudflared on the box dials outbound to CF's edge (NAT/double-NAT-agnostic); CF
# terminates TLS at the anycast edge and routes the tunnel to the box's local Traefik.
# Split horizon: on-Slate-WiFi clients resolve app.demo → 192.168.8.10 via dnsmasq;
# everyone else resolves the proxied CNAME below → tunnel → box.

# Tunnel password (base64 of >=32 random bytes). Modifying forces tunnel replacement.
resource "random_id" "demo_tunnel_secret" {
  byte_length = 35
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "demo_edge" {
  account_id = var.account_id
  name       = "trakrf-demo-edge"
  secret     = random_id.demo_tunnel_secret.b64_std
  config_src = "cloudflare" # ingress managed here in TF, not a local YAML on the box
}

# Ingress: app.demo.trakrf.id → box Traefik. The cloudflared→traefik leg is box-local
# (same podman bridge), so no_tls_verify decouples the public path from the box's LE
# cert expiry; http_host_header carries the public hostname so Traefik routes correctly.
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "demo_edge" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.demo_edge.id

  config {
    ingress_rule {
      hostname = "app.demo.${var.domain_name}"
      service  = "https://traefik:443"
      origin_request {
        http_host_header = "app.demo.${var.domain_name}"
        no_tls_verify    = true
      }
    }
    ingress_rule {
      service = "http_status:404" # required catch-all
    }
  }
}

# Replaces the stale public A app.demo → 192.168.8.10 (deleted out-of-band in Task A4).
resource "cloudflare_record" "app_demo" {
  zone_id = cloudflare_zone.domain.id
  name    = "app.demo"
  content = cloudflare_zero_trust_tunnel_cloudflared.demo_edge.cname # <tunnel-id>.cfargotunnel.com
  type    = "CNAME"
  proxied = true
  comment = "TRA-957 — edge demo box via CF Tunnel (split-horizon public path)"
}
```

- [ ] **Step 2: Add the token output**

In `terraform/cloudflare/outputs.tf`, append:

```hcl
# Cloudflare Tunnel connector token for the edge demo box (TRA-957).
# Consumed by `just tunnel-token` → platform/deploy/edge/.env (TUNNEL_TOKEN).
output "demo_tunnel_token" {
  value     = cloudflare_zero_trust_tunnel_cloudflared.demo_edge.tunnel_token
  sensitive = true
}
```

- [ ] **Step 3: Add the `tunnel-token` justfile recipe**

In `justfile`, after the `origin-cert-secret` recipe, add:

```just
# Print the edge demo Cloudflare Tunnel token (TRA-957). Pipe into the box's
# platform/deploy/edge/.env as TUNNEL_TOKEN. Sensitive — don't commit/log.
tunnel-token:
    @tofu -chdir=terraform/cloudflare output -raw demo_tunnel_token
```

- [ ] **Step 4: Validate**

```bash
tofu -chdir=terraform/cloudflare validate
```
Expected: `Success! The configuration is valid.`

---

### Task A3: Plan (verification gate)

- [ ] **Step 1: Run plan**

```bash
cd /home/mike/infra
tofu -chdir=terraform/cloudflare plan
```
Expected: a plan adding exactly **4** resources — `random_id.demo_tunnel_secret`, `cloudflare_zero_trust_tunnel_cloudflared.demo_edge`, `cloudflare_zero_trust_tunnel_cloudflared_config.demo_edge`, `cloudflare_record.app_demo` — and **no** changes/destroys to existing resources. Report the actual output.

- [ ] **Step 2: Commit the Terraform**

```bash
git add terraform/cloudflare/versions.tf terraform/cloudflare/.terraform.lock.hcl \
        terraform/cloudflare/demo-tunnel.tf terraform/cloudflare/outputs.tf justfile
git commit -m "feat(cloudflare): add edge demo CF Tunnel + ingress + CNAME (TRA-957)"
```

---

### Task A4: Delete the stale A record, then apply

**Why:** A CNAME can't coexist with the existing unmanaged `A app.demo → 192.168.8.10`. It is not in TF state, so it must be removed via the API first or `apply` will fail with "record already exists".

- [ ] **Step 1: Load env**

```bash
cd /home/mike/infra
set -a; . ./.env.local; set +a
```

- [ ] **Step 2: Resolve zone id and find the stale A record**

```bash
ZONE_ID=$(tofu -chdir=terraform/cloudflare output -raw zone_id)
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=app.demo.trakrf.id" \
  | jq -r '.result[] | "\(.id)\t\(.content)\tproxied=\(.proxied)"'
```
Expected: one line with content `192.168.8.10`. Capture its id. **If content is NOT `192.168.8.10`, STOP and reassess** — do not delete an unexpected record.

- [ ] **Step 3: Delete it**

```bash
REC_ID=<id from step 2>
curl -s -X DELETE -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$REC_ID" | jq '.success'
```
Expected: `true`.

- [ ] **Step 4: Apply**

```bash
just cloudflare
```
Expected: `Apply complete! Resources: 4 added, 0 changed, 0 destroyed.` Report actual output.

- [ ] **Step 5: Verify the CNAME resolves to the tunnel**

```bash
dig +short app.demo.trakrf.id CNAME
dig +short app.demo.trakrf.id
```
Expected: CNAME → `<tunnel-id>.cfargotunnel.com`, and an A answer from Cloudflare's proxy IP ranges (104.x / 172.6x). (The edge will return error 1016 until Phase B connects the tunnel — expected.)

---

### Task A5: Hand off token + open infra PR

- [ ] **Step 1: Retrieve the tunnel token into the box `.env`**

```bash
cd /home/mike/infra
TOKEN=$(just tunnel-token)
# write into platform .env (created/updated in Phase B); store now to avoid re-running
printf 'TUNNEL_TOKEN=%s\n' "$TOKEN" >> /home/mike/platform/deploy/edge/.env
```
> The value is sensitive — do not echo it to logs or commit it. `.env` is gitignored.

- [ ] **Step 2: Push branch and open PR**

```bash
cd /home/mike/infra
git push -u origin miks2u/tra-957-expose-edge-demo-app-publicly-via-cloudflare-tunnel
gh pr create --base main --title "feat(cloudflare): edge demo CF Tunnel public exposure (TRA-957)" \
  --body "Implements the infra side of TRA-957: Cloudflare Tunnel + remotely-managed ingress (app.demo.trakrf.id → box Traefik, box-local leg no_tls_verify) + proxied CNAME replacing the stale private A record. Token surfaced via \`just tunnel-token\`. Box-side cloudflared + cert-renewal in trakrf/platform.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

---

## Phase B — Box (platform `deploy/edge`)

### Task B1: Create the platform branch

- [ ] **Step 1: Branch**

```bash
cd /home/mike/platform
git fetch origin && git checkout -b feat/tra-957-cloudflared-edge-tunnel origin/main
```
Expected: new branch off latest `main`.

> If `deploy/edge/.env` already has `TUNNEL_TOKEN` from Task A5, leave it — `.env` is gitignored.

---

### Task B2: cloudflared quadlet

**Files:**
- Create: `deploy/edge/quadlets/cloudflared.container`

- [ ] **Step 1: Create the quadlet**

```ini
[Unit]
Description=Cloudflare Tunnel (edge demo public ingress)
After=traefik.service
Requires=traefik.service

[Container]
ContainerName=cloudflared
Image=docker.io/cloudflare/cloudflared:2026.5.2
Network=trakrf.network
EnvironmentFile=%h/platform/deploy/edge/.env
Exec=tunnel --no-autoupdate run

[Service]
Restart=always

[Install]
WantedBy=default.target
```
> `cloudflared` reads `TUNNEL_TOKEN` from the env file — no `--token` on argv (keeps it out of `podman inspect`/process list). On `trakrf.network` so `https://traefik:443` resolves by container DNS.

---

### Task B3: Cert renewal script + systemd units

**Files:**
- Create: `deploy/edge/renew-cert.sh`
- Create: `deploy/edge/systemd/cert-renew.service`
- Create: `deploy/edge/systemd/cert-renew.timer`

- [ ] **Step 1: Create `deploy/edge/renew-cert.sh`**

```bash
#!/usr/bin/env bash
# Opportunistic LE renewal for app.demo.trakrf.id via Cloudflare DNS-01 (outbound-only).
# `lego renew --days 30` is a no-op unless within 30 days of expiry (and a clean no-op
# when offline). On an actual renewal, deploy the cert and reload Traefik. (TRA-957)
set -euo pipefail
cd "$(dirname "$0")"
CERT=traefik/lego/certificates/app.demo.trakrf.id.crt

before=$(sha256sum "$CERT" | awk '{print $1}')
podman run --rm \
  -e CLOUDFLARE_DNS_API_TOKEN \
  -v "$PWD/traefik/lego:/.lego:Z" \
  docker.io/goacme/lego:latest \
  --accept-tos --email admin@trakrf.id \
  --dns cloudflare --domains app.demo.trakrf.id \
  --path /.lego renew --days 30
after=$(sha256sum "$CERT" | awk '{print $1}')

if [ "$before" != "$after" ]; then
  echo "cert renewed — deploying and reloading Traefik"
  cp traefik/lego/certificates/app.demo.trakrf.id.crt traefik/certs/app.demo.trakrf.id.crt
  cp traefik/lego/certificates/app.demo.trakrf.id.key traefik/certs/app.demo.trakrf.id.key
  chmod 600 traefik/certs/app.demo.trakrf.id.key
  systemctl --user restart traefik
else
  echo "cert not due for renewal — no-op"
fi
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x /home/mike/platform/deploy/edge/renew-cert.sh
```

- [ ] **Step 3: Create `deploy/edge/systemd/cert-renew.service`**

```ini
[Unit]
Description=Renew app.demo.trakrf.id LE cert (DNS-01) if near expiry

[Service]
Type=oneshot
EnvironmentFile=%h/platform/deploy/edge/.env
ExecStart=%h/platform/deploy/edge/renew-cert.sh
```

- [ ] **Step 4: Create `deploy/edge/systemd/cert-renew.timer`**

```ini
[Unit]
Description=Daily opportunistic LE cert renewal for app.demo.trakrf.id

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
```

---

### Task B4: Wire installs + env docs

**Files:**
- Modify: `deploy/edge/install.sh`
- Modify: `deploy/edge/.env.example`

- [ ] **Step 1: Extend `install.sh` to symlink the systemd user units and enable the timer**

Replace the body of `deploy/edge/install.sh` with:

```bash
#!/usr/bin/env bash
# Symlink deploy/edge quadlets + systemd user units into the rootless dirs and reload.
set -euo pipefail
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# Podman quadlets
QDEST="$HOME/.config/containers/systemd"
mkdir -p "$QDEST"
for f in "$HERE"/quadlets/*.container "$HERE"/quadlets/*.network; do
  [ -e "$f" ] || continue
  ln -sf "$f" "$QDEST/$(basename "$f")"
done

# systemd user units (cert renewal timer)
UDEST="$HOME/.config/systemd/user"
mkdir -p "$UDEST"
for f in "$HERE"/systemd/*.service "$HERE"/systemd/*.timer; do
  [ -e "$f" ] || continue
  ln -sf "$f" "$UDEST/$(basename "$f")"
done

systemctl --user daemon-reload
systemctl --user enable --now cert-renew.timer 2>/dev/null || true

echo "Linked quadlets:"; ls -l "$QDEST"
echo "Linked user units:"; ls -l "$UDEST"
```

- [ ] **Step 2: Add token placeholders to `.env.example`**

Append to `deploy/edge/.env.example`:

```
# Cloudflare Tunnel token (TRA-957) — get from `just tunnel-token` in trakrf/infra
TUNNEL_TOKEN=CHANGEME
# Cloudflare DNS API token for lego DNS-01 cert renewal (TRA-957) — Zone:DNS:Edit on trakrf.id
CLOUDFLARE_DNS_API_TOKEN=CHANGEME
```

---

### Task B5: Configure secrets on the box

- [ ] **Step 1: Ensure `TUNNEL_TOKEN` is set**

```bash
grep -q '^TUNNEL_TOKEN=' /home/mike/platform/deploy/edge/.env && echo "TUNNEL_TOKEN present" || echo "MISSING — run: just tunnel-token (infra) >> .env"
```
Expected: `TUNNEL_TOKEN present` (set in Task A5).

- [ ] **Step 2: Set `CLOUDFLARE_DNS_API_TOKEN`**

> **Decision point — confirm with the user before writing.** The renewal timer needs a Cloudflare token with `Zone:DNS:Edit` + `Zone:Zone:Read` on `trakrf.id`. Options: (a) reuse the infra provider token (`CLOUDFLARE_API_TOKEN` from infra `.env.local`), or (b) a dedicated DNS-scoped token. Ask which; then:

```bash
printf 'CLOUDFLARE_DNS_API_TOKEN=%s\n' "<token>" >> /home/mike/platform/deploy/edge/.env
```
> Sensitive — `.env` is gitignored; do not echo or commit the value.

---

### Task B6: Install, start, and verify end-to-end

- [ ] **Step 1: Install units**

```bash
cd /home/mike/platform/deploy/edge && ./install.sh
```
Expected: lists both `cloudflared.container` (quadlet) and `cert-renew.{service,timer}` (user units).

- [ ] **Step 2: Start cloudflared**

```bash
systemctl --user daemon-reload
systemctl --user start cloudflared.service
sleep 5
systemctl --user status cloudflared.service --no-pager | head -20
podman logs cloudflared 2>&1 | tail -20
```
Expected: container `active (running)`; logs show `Registered tunnel connection` ~4 times (4 edge connections).

- [ ] **Step 3: Verify public path off-LAN**

From a device **not** on the Slate WiFi (e.g. phone on cellular), or from the box bypassing split-horizon DNS:

```bash
# Force-resolve through Cloudflare (ignores any local dnsmasq override):
curl -sS -o /dev/null -w '%{http_code} %{ssl_verify_result}\n' \
  --resolve app.demo.trakrf.id:443:104.16.0.0 https://app.demo.trakrf.id/ || true
# Authoritative check: load from a real off-LAN client and confirm the app renders.
```
Expected: `200` with a valid Cloudflare edge cert (CF error 1016 means the tunnel isn't connected — re-check Step 2). Confirm Live Reads/SSE: open the live feed off-LAN and verify it streams and reconnects after ~100s without erroring out.

- [ ] **Step 4: Verify split horizon intact**

On a Slate-WiFi client: `dig +short app.demo.trakrf.id` → `192.168.8.10` (local dnsmasq override still wins on-site).

- [ ] **Step 5: Verify the renewal timer**

```bash
systemctl --user list-timers cert-renew.timer --no-pager
systemctl --user start cert-renew.service   # one manual run
journalctl --user -u cert-renew.service --no-pager | tail -15
```
Expected: timer listed/active with a next-run time; the manual run logs `cert not due for renewal — no-op` (cert is fresh until Sep 5 2026) and exits 0.

---

### Task B7: Commit + open platform PR

- [ ] **Step 1: Commit**

```bash
cd /home/mike/platform
git add deploy/edge/quadlets/cloudflared.container deploy/edge/renew-cert.sh \
        deploy/edge/systemd/cert-renew.service deploy/edge/systemd/cert-renew.timer \
        deploy/edge/install.sh deploy/edge/.env.example
git commit -m "feat(edge): cloudflared tunnel quadlet + opportunistic LE cert renewal (TRA-957)"
```

- [ ] **Step 2: Push + PR**

```bash
git push -u origin feat/tra-957-cloudflared-edge-tunnel
gh pr create --base main --title "feat(edge): cloudflared tunnel + cert renewal (TRA-957)" \
  --body "Box side of TRA-957: cloudflared quadlet (pinned 2026.5.2) running the TF-minted tunnel token from .env, on trakrf.network → traefik:443. Adds opportunistic DNS-01 cert renewal (renew-cert.sh + cert-renew.service/.timer) now that the tunnel makes the box always-on. install.sh symlinks the new user units; .env.example documents the two new tokens.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

---

## Self-Review notes

- **Spec coverage:** tunnel/ingress/CNAME (A2), token output + recipe (A2/A5), stale-A removal (A4), cloudflared quadlet + token-from-env (B2/B5), `no_tls_verify` decoupling (A2), opportunistic renewal (B3/B4/B6), split-horizon left untouched (verified B6.4). All acceptance criteria mapped.
- **Apply-order gotcha:** A4 deletes the A record before `just cloudflare` apply — the one ordering hazard, called out explicitly.
- **Secrets:** `TUNNEL_TOKEN` + `CLOUDFLARE_DNS_API_TOKEN` only ever land in the gitignored `.env`; never committed or logged. `CLOUDFLARE_DNS_API_TOKEN` source is an explicit decision point (B5.2).
- **Cross-repo:** infra and platform land as two PRs but must be applied together (CNAME 1016s until cloudflared connects) — sequencing handled (Phase A apply → token handoff → Phase B start).
