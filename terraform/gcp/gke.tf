# GKE cluster — single on-demand primary node runs everything (DB + app + platform).
# Standard (not Autopilot) because CNPG/kube-prom/Traefik need privileged pods and
# non-GKE DaemonSets that Autopilot blocks. Zonal for $0 control plane.
resource "google_container_cluster" "main" {
  name     = "gke-${local.name_prefix}"
  location = var.zone

  # We manage the node pool as a separate resource so we can change its shape
  # without recreating the cluster. This pair of fields is the canonical way.
  remove_default_node_pool = true
  initial_node_count       = 1

  # Provider v6 defaults this to true; we destroy + rebuild during demo iteration.
  deletion_protection = false

  # Auto-allocate pod and service secondary ranges from the default VPC.
  ip_allocation_policy {}

  # Workload Identity — required for cert-manager Cloud DNS solver in TRA-461.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  release_channel {
    channel = "REGULAR"
  }

  resource_labels = local.common_labels
}

# Primary node pool — on-demand ARM, single zone. Single pool; DB + app + platform
# co-located (same topology as the AKS demo primary). CNPG node pinning and spot
# burst are deferred (TRA-364-class work for a later phase).
resource "google_container_node_pool" "primary" {
  name     = "primary"
  cluster  = google_container_cluster.main.name
  location = var.zone

  node_count = 1

  node_config {
    machine_type = var.node_machine_type
    image_type   = "COS_CONTAINERD"
    disk_size_gb = 50

    # Required companion to cluster-level workload_identity_config — without this
    # the GKE metadata server won't run on the node and SAs can't federate tokens.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = local.common_labels
  }
}
