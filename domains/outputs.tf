output "zone_id" {
  value = cloudflare_zone.domain.id
}

output "nameservers" {
  value = cloudflare_zone.domain.name_servers
}
