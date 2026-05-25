output "zone_id" {
  value = cloudflare_zone.domain.id
}

output "nameservers" {
  value = cloudflare_zone.domain.name_servers
}

# Cloudflare Origin CA cert + private key for trakrf.id origin TLS.
# Consumed by `just origin-cert-secret` to materialize the
# trakrf-id-origin-tls Secret in the trakrf-system namespace.
output "origin_ca_cert_pem" {
  value     = cloudflare_origin_ca_certificate.trakrf_id.certificate
  sensitive = true
}

output "origin_ca_private_key_pem" {
  value     = tls_private_key.origin_ca.private_key_pem
  sensitive = true
}

# Cloudflare IPv4 / IPv6 CIDRs. Consumed by scripts/apply-root-app.sh
# to populate the cloudflare-allow IPAllowList sourceRange.
output "cloudflare_ipv4_cidrs" {
  value = data.cloudflare_ip_ranges.this.ipv4_cidr_blocks
}

output "cloudflare_ipv6_cidrs" {
  value = data.cloudflare_ip_ranges.this.ipv6_cidr_blocks
}
