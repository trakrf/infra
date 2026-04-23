# TRA-459: required service APIs for the GKE rollout.
# compute.googleapis.com is a hard transitive dep of GKE (VMs, networks, disks);
# enabling it here avoids a phase-2 apply surprise. Artifact Registry, IAM
# Credentials, and other APIs land alongside the resources that need them in
# TRA-460 and later phases.

resource "google_project_service" "required" {
  for_each = toset([
    "container.googleapis.com",
    "compute.googleapis.com",
    "dns.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
  ])

  service = each.key

  # Keep services enabled if this resource is removed from state.
  # Disabling APIs on a live project can break running resources.
  disable_on_destroy = false
}
