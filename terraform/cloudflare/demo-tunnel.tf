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

# Replaces the stale public A app.demo → 192.168.8.10 (deleted out-of-band at apply time).
resource "cloudflare_record" "app_demo" {
  zone_id = cloudflare_zone.domain.id
  name    = "app.demo"
  content = cloudflare_zero_trust_tunnel_cloudflared.demo_edge.cname # <tunnel-id>.cfargotunnel.com
  type    = "CNAME"
  proxied = true
  comment = "TRA-957 — edge demo box via CF Tunnel (split-horizon public path)"
}
