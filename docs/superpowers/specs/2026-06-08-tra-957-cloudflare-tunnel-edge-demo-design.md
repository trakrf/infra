# TRA-957 — Expose edge demo app publicly via Cloudflare Tunnel

**Date:** 2026-06-08
**Linear:** [TRA-957](https://linear.app/trakrf/issue/TRA-957)
**Repos:** `trakrf/infra` (Terraform — Cloudflare resources) + `trakrf/platform` (`deploy/edge` — box-side quadlet)

## Goal

Let demo participants reach `https://app.demo.trakrf.id` from any network (cellular, venue
WiFi) **without joining the Slate's WiFi** and without inbound reachability. The demo box sits
behind venue NAT → double-NAT, so port-forward / dyndns is a non-starter.

`cloudflared` runs on the demo box and dials **outbound** to Cloudflare's edge (NAT-agnostic,
no public IP). Cloudflare terminates TLS at its anycast edge for `app.demo.trakrf.id` and routes
the tunnel to the box's local Traefik. Same posture as the GKE app (already behind Cloudflare),
so no new data-exposure concern.

## Context (verified 2026-06-08)

- `trakrf.id` is a Cloudflare zone managed in `terraform/cloudflare` (`cloudflare_zone.domain`,
  `var.domain_name = trakrf.id`, account `44e11a8…`).
- Cloudflare provider is pinned at **v4.52.7** → resources are `cloudflare_zero_trust_tunnel_cloudflared`,
  `cloudflare_zero_trust_tunnel_cloudflared_config`, `cloudflare_record`.
- `app.demo.trakrf.id` currently has an **unmanaged** public `A → 192.168.8.10` (private IP;
  resolves but unreachable off-LAN). Not in TF state — must be deleted out-of-band before the
  CNAME can be created (CNAME cannot coexist with A at the same name).
- The box (`trakrf-demo`, this host = `192.168.8.10`) runs rootless podman with quadlets in
  `~/.config/containers/systemd/` symlinked from `platform/deploy/edge/quadlets/`. Running
  containers: `traefik` (v3.3, :443), `backend`, `mosquitto`, `timescaledb`. All on the
  `trakrf` podman network (DNS: `traefik` resolves to the Traefik container).
- The box has a valid Let's Encrypt cert for `app.demo.trakrf.id` (lego/DNS-01) on Traefik —
  kept for LAN/origin; the public path uses Cloudflare's edge cert.

## Architecture

```
off-LAN client ──TLS──> Cloudflare edge ──tunnel──> cloudflared (box) ──https://traefik:443──> Traefik ──> backend
   (CF edge cert for app.demo.trakrf.id)              (TUNNEL_TOKEN)        (box-local leg, no_tls_verify)
```

The `cloudflared → traefik` leg is **box-local** (both containers on the same podman bridge;
traffic never leaves the host), so it uses `no_tls_verify = true`. This deliberately **decouples
the public path from the box's Let's Encrypt cert** — if that cert lapses, the public tunnel
keeps serving (only LAN-direct clients would see a TLS error). `http_host_header` still carries
the public hostname so Traefik routes correctly. See *Cert renewal* below for keeping the
LAN/origin cert fresh.

Split horizon (unchanged): the Slate's dnsmasq override `app.demo.trakrf.id → 192.168.8.10`
stays, so on-Slate-WiFi devices go direct/local; everyone else resolves the public CF CNAME →
tunnel → box.

## Infra changes (`trakrf/infra`)

### New file: `terraform/cloudflare/demo-tunnel.tf`

1. **Tunnel secret** — new `hashicorp/random` provider:
   ```hcl
   resource "random_id" "demo_tunnel_secret" {
     byte_length = 35   # >32 bytes; .b64_std is the tunnel password
   }
   ```

2. **Tunnel** — remotely-managed config (`config_src = "cloudflare"`) so ingress lives in TF:
   ```hcl
   resource "cloudflare_zero_trust_tunnel_cloudflared" "demo_edge" {
     account_id = var.account_id
     name       = "trakrf-demo-edge"
     secret     = random_id.demo_tunnel_secret.b64_std
     config_src = "cloudflare"
   }
   ```

3. **Ingress config** — route hostname to Traefik over TLS; set Host header + SNI to the public
   name so Traefik's LE cert validates and the route matches:
   ```hcl
   resource "cloudflare_zero_trust_tunnel_cloudflared_config" "demo_edge" {
     account_id = var.account_id
     tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.demo_edge.id
     config {
       ingress_rule {
         hostname = "app.demo.${var.domain_name}"
         service  = "https://traefik:443"
         origin_request {
           http_host_header = "app.demo.${var.domain_name}"  # route on Traefik
           no_tls_verify    = true                            # box-local leg; decouple from LE expiry
         }
       }
       ingress_rule { service = "http_status:404" }   # required catch-all
     }
   }
   ```

4. **DNS** — proxied CNAME replacing the stale A record:
   ```hcl
   resource "cloudflare_record" "app_demo" {
     zone_id = cloudflare_zone.domain.id
     name    = "app.demo"
     content = cloudflare_zero_trust_tunnel_cloudflared.demo_edge.cname  # <id>.cfargotunnel.com
     type    = "CNAME"
     proxied = true
     comment = "TRA-957 — edge demo box via CF Tunnel (split-horizon public path)"
   }
   ```

### `terraform/cloudflare/versions.tf`
Add `hashicorp/random ~> 3.0` to `required_providers`; `tofu init -upgrade` to fetch it and
update `.terraform.lock.hcl`.

### `terraform/cloudflare/outputs.tf`
```hcl
output "demo_tunnel_token" {
  value     = cloudflare_zero_trust_tunnel_cloudflared.demo_edge.tunnel_token
  sensitive = true
}
```

### `justfile`
`tunnel-token` recipe → `tofu -chdir=terraform/cloudflare output -raw demo_tunnel_token`
(mirrors the existing `origin-cert-secret` pattern). Used to hand the token to the box `.env`.

## Box changes (`trakrf/platform`, `deploy/edge`)

### New file: `quadlets/cloudflared.container`
```ini
[Unit]
Description=Cloudflare Tunnel (edge demo public ingress)
After=traefik.service
Requires=traefik.service

[Container]
ContainerName=cloudflared
Image=docker.io/cloudflare/cloudflared:<pinned recent tag, verified to pull>
Network=trakrf.network
EnvironmentFile=%h/platform/deploy/edge/.env
Exec=tunnel --no-autoupdate run

[Service]
Restart=always

[Install]
WantedBy=default.target
```
- `cloudflared` reads `TUNNEL_TOKEN` from env → token lives in the gitignored `.env` (not argv,
  so it stays out of `podman inspect` / process list).
- `trakrf.network` → reaches `https://traefik:443` by container DNS.
- `install.sh` already globs `*.container` → auto-symlinks the new quadlet (no change).

### `.env.example`
Add placeholders with pointers to the sources of truth:
```
# Cloudflare Tunnel token (TRA-957) — get from `just tunnel-token` in trakrf/infra
TUNNEL_TOKEN=CHANGEME
# Cloudflare DNS API token for lego DNS-01 cert renewal (TRA-957)
CLOUDFLARE_DNS_API_TOKEN=CHANGEME
```

### Cert renewal — opportunistic, always-on

The box's LE cert (`app.demo.trakrf.id`, 90-day) is currently renewed **manually** at pre-event
prep — a model that assumed the box was offline at venues. The tunnel makes the box always-on, so
we add hands-free renewal. DNS-01 is **outbound-only** (needs only `CLOUDFLARE_DNS_API_TOKEN` +
internet egress; no inbound), so it works whenever the uplink is up.

- **`renew-cert.sh`** (new, `deploy/edge/`): runs the `goacme/lego` container with
  `renew --days 30` against the mounted `traefik/lego/` account+cert. `lego renew` is inherently
  opportunistic — a no-op unless within 30 days of expiry, and a clean no-op (retry next tick)
  when offline. On an actual renewal (detected by cert-file checksum change), it copies the new
  cert/key into `traefik/certs/` (`chmod 600` the key) and `systemctl --user restart traefik`.
- **`systemd/cert-renew.service`** (new): `Type=oneshot`, `EnvironmentFile=…/.env` (for
  `CLOUDFLARE_DNS_API_TOKEN`), `ExecStart=…/renew-cert.sh`.
- **`systemd/cert-renew.timer`** (new): `OnCalendar=daily`, `Persistent=true` (catches up after
  downtime).
- **`install.sh`**: extend to also symlink `systemd/*.{service,timer}` into
  `~/.config/systemd/user/` and `systemctl --user enable --now cert-renew.timer`.
- **Linger**: confirm `loginctl enable-linger mike` so user timers (and the quadlets) fire
  headless without an active login session.

The infra-side `origin_request.no_tls_verify` already makes the **public** path robust even if a
renewal is somehow missed; this timer keeps the **LAN/origin** cert fresh automatically.

## Apply sequence

1. **infra**: `tofu init -upgrade` (fetch random provider, update lock).
2. **Delete the stale unmanaged `A app.demo → 192.168.8.10`** via Cloudflare API (one-time; not
   in TF state — would otherwise block the CNAME).
3. **infra**: `just cloudflare` → plan + apply (tunnel, ingress config, CNAME).
4. **infra**: `just tunnel-token` → copy token into `platform/deploy/edge/.env` as `TUNNEL_TOKEN`.
5. **box**: pin/verify the cloudflared image; set `TUNNEL_TOKEN` + `CLOUDFLARE_DNS_API_TOKEN` in
   `.env`; `install.sh` (symlinks quadlet + renewal units); `loginctl enable-linger`;
   `systemctl --user daemon-reload`; `systemctl --user start cloudflared`;
   `systemctl --user enable --now cert-renew.timer`.
6. **verify**: `cloudflared` registers 4 edge connections; `https://app.demo.trakrf.id` loads
   off-LAN (cellular) with a valid CF cert; Live Reads/SSE reconnect-and-resume; `cert-renew.timer`
   is listed/active and a manual `cert-renew.service` run is a clean no-op (cert not near expiry).

## Gotchas

- **A→CNAME conflict** — the stale A record must be deleted before the CNAME applies (step 2).
- **SSE / Live Reads** — Cloudflare's proxy has a ~100s read timeout on long-lived connections.
  `EventSource` auto-reconnects, so the feed blips-and-resumes. Acceptable; WebSockets are an
  option if we switch later.
- **TLS to origin** — the `cloudflared → traefik` leg is box-local, so it uses `no_tls_verify`,
  decoupling the public path from LE cert expiry. The LAN/origin cert is kept fresh by the
  `cert-renew.timer` (DNS-01, outbound-only).
- **Edge errors until the box connects** — once the CNAME flips, the hostname returns CF error
  1016 until `cloudflared` is running on the box. Apply infra and box side together.
- **Two-label host needs ACM (found during apply, TRA-957)** — `app.demo.trakrf.id` is two
  labels deep, so Free Universal SSL's `*.trakrf.id` does NOT cover it; the edge TLS handshake
  fails (`sslv3 alert handshake failure`) even with the tunnel connected. Fix: a
  `cloudflare_certificate_pack` advanced cert for `app.demo.trakrf.id` (`acm-demo.tf`) — same
  gotcha/pattern as `app.preview.trakrf.id` (TRA-856). The zone already has ACM enabled, so no
  billing action; the `terraform-infrastructure` token already has `SSL and Certificates Write`.
- **Tunnel API token perm (found during apply)** — managing `cloudflare_zero_trust_tunnel_*`
  needs account-scoped `Cloudflare Tunnel Read/Write`, which the `terraform-infrastructure` token
  lacked (error 10000). Added in `terraform/bootstrap/main.tf` (in-place token update).

## Acceptance criteria

- [ ] Tunnel + ingress + DNS CNAME defined in `trakrf/infra` Terraform (no click-ops).
- [ ] `cloudflared` runs on the box from a quadlet using a secret-sourced token.
- [ ] `https://app.demo.trakrf.id` loads the edge app off-LAN with a valid CF cert.
- [ ] On-Slate-WiFi clients still resolve to `.10` (split horizon intact).
- [ ] Live Reads / SSE works over the tunnel (reconnect behavior acceptable).
- [ ] Stale `A → 192.168.8.10` public record removed/replaced.
- [ ] Edge cert for the two-label host provided by ACM advanced cert (`acm-demo.tf`).
- [ ] Public path is robust to LE cert expiry (box-local leg uses `no_tls_verify`).
- [ ] LE cert renews hands-free when the box has uplink (`cert-renew.timer` installed + enabled).

## Out of scope

- Switching SSE → WebSockets.
- Tunnel for any host other than `app.demo.trakrf.id`.
- Tailscale Funnel / proxy-VM alternatives (CF Tunnel chosen for the branded domain).
