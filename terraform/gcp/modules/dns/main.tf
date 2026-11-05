# DNS Module — Cloud DNS Records
#
# A records pointing at the GKE ingress load balancer IP for the named
# platform hosts (api, registry, ...) and the app wildcard *.apps.<domain>.
#
# There is deliberately no apex or "*.<domain>" wildcard: with them every
# name under the domain resolved to the platform ingress, so a project could
# register a platform-looking host (auth., sso., ...) as a custom domain and
# pass DNS verification. legacy_wildcard_records keeps the old records for a
# two-step migration only (see CHANGELOG 2026-11-05).

data "google_dns_managed_zone" "main" {
  name = var.dns_zone_name
}

resource "google_dns_record_set" "platform" {
  for_each = toset(var.platform_hosts)

  name         = "${each.value}.${var.domain}."
  managed_zone = data.google_dns_managed_zone.main.name
  type         = "A"
  ttl          = 300
  rrdatas      = [var.public_ip]
}

# Apps are served at <component>.<org>-<project>-<env>.<EVE_DEFAULT_DOMAIN>,
# so EVE_DEFAULT_DOMAIN must be apps.<domain>.
resource "google_dns_record_set" "apps_wildcard" {
  name         = "*.apps.${var.domain}."
  managed_zone = data.google_dns_managed_zone.main.name
  type         = "A"
  ttl          = 300
  rrdatas      = [var.public_ip]
}

# The registry record predates platform_hosts; keep it in place.
moved {
  from = google_dns_record_set.registry
  to   = google_dns_record_set.platform["registry"]
}

# -----------------------------------------------------------------------------
# Legacy apex and wildcard records (migration only; default off)
# -----------------------------------------------------------------------------

resource "google_dns_record_set" "apex" {
  count = var.legacy_wildcard_records ? 1 : 0

  name         = "${var.domain}."
  managed_zone = data.google_dns_managed_zone.main.name
  type         = "A"
  ttl          = 300
  rrdatas      = [var.public_ip]
}

resource "google_dns_record_set" "wildcard" {
  count = var.legacy_wildcard_records ? 1 : 0

  name         = "*.${var.domain}."
  managed_zone = data.google_dns_managed_zone.main.name
  type         = "A"
  ttl          = 300
  rrdatas      = [var.public_ip]
}

moved {
  from = google_dns_record_set.apex
  to   = google_dns_record_set.apex[0]
}

moved {
  from = google_dns_record_set.wildcard
  to   = google_dns_record_set.wildcard[0]
}
