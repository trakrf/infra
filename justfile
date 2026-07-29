# env_var_or_default (not env_var): these must NOT hard-fail just to load the
# justfile. Recipes that actually need them call require_tf_env (see
# scripts/ops-lib.sh) for a clear error instead of a raw `env_var` failure or
# tofu running against an empty TF_VAR_*. See docs/ops.md and TRA-1037 C1.
export TF_VAR_account_id := env_var_or_default("CLOUDFLARE_ACCOUNT_ID", "")
export TF_VAR_bucket_name := env_var_or_default("CLOUDFLARE_TF_STATE_BUCKET", "")
export TF_VAR_domain_name := env_var_or_default("DOMAIN_NAME", "")
export TF_VAR_eks_nlb_hostname := env_var_or_default("EKS_NLB_HOSTNAME", "")

r2_endpoint := "https://" + env_var_or_default("CLOUDFLARE_ACCOUNT_ID", "") + ".r2.cloudflarestorage.com"

# GKE ops coordinates — deliberately literal. `gke-creds` used to derive these
# from `tofu -chdir=terraform/gcp output`, which puts R2 state between an
# operator and prod during an incident. If the cluster is ever rebuilt,
# re-derive with `tofu -chdir=terraform/gcp output` and update these three.
gcp_project := "trakrf-494211"
gcp_zone    := "us-central1-a"
gke_cluster := "gke-trakrf-demo-usc1"
gke_context := "gke_" + gcp_project + "_" + gcp_zone + "_" + gke_cluster

default: list

# List available recipes
list:
  @just --list

# Print environment variables
env:
    @env

# Generate backend.conf for S3/R2 endpoint (gitignored, never committed)
_backend-conf dir:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/ops-lib.sh
    require_tf_env
    printf 'endpoints = { s3 = "%s" }\nprofile = "cloudflare-r2"\n' "{{r2_endpoint}}" > {{dir}}/backend.conf

# One-time setup: create R2 state bucket and API tokens
bootstrap:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/ops-lib.sh
    require_tf_env
    echo "Bootstrapping cloudflare resources on ${DOMAIN_NAME}"
    CLOUDFLARE_API_TOKEN=$CLOUDFLARE_BOOTSTRAP_API_TOKEN tofu -chdir=terraform/bootstrap init
    CLOUDFLARE_API_TOKEN=$CLOUDFLARE_BOOTSTRAP_API_TOKEN tofu -chdir=terraform/bootstrap plan -out=tfplan
    CLOUDFLARE_API_TOKEN=$CLOUDFLARE_BOOTSTRAP_API_TOKEN tofu -chdir=terraform/bootstrap apply tfplan | grep -v '<sensitive>'
    CLOUDFLARE_API_TOKEN=$CLOUDFLARE_BOOTSTRAP_API_TOKEN tofu -chdir=terraform/bootstrap output -show-sensitive | grep -E '(secret|infra)'

# Plan and apply Cloudflare DNS and Pages resources
cloudflare: (_backend-conf "terraform/cloudflare")
    @echo "Planning Cloudflare resources on ${DOMAIN_NAME}"
    @tofu -chdir=terraform/cloudflare init -backend-config=backend.conf
    @tofu -chdir=terraform/cloudflare plan -out=tfplan
    @tofu -chdir=terraform/cloudflare apply tfplan

# Materialize the Cloudflare Origin Cert into a Kubernetes Secret with
# reflector annotations so it mirrors into trakrf-preview and trakrf-prod.
# Run AFTER `just cloudflare` mints/rotates the cert. Idempotent.
#
# Requires kubectl context pointed at the target GKE cluster.
origin-cert-secret:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/ops-lib.sh
    require_tf_env
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    tofu -chdir=terraform/cloudflare output -raw origin_ca_cert_pem > "$tmp/tls.crt"
    tofu -chdir=terraform/cloudflare output -raw origin_ca_private_key_pem > "$tmp/tls.key"
    kubectl create namespace trakrf-system --dry-run=client -o yaml | kubectl apply -f -
    kubectl create secret tls trakrf-id-origin-tls \
        --cert="$tmp/tls.crt" --key="$tmp/tls.key" \
        --namespace trakrf-system \
        --dry-run=client -o yaml \
      | kubectl annotate --local -f - --overwrite \
          reflector.v1.k8s.emberstack.com/reflection-allowed=true \
          'reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces=trakrf-preview,trakrf-prod,monitoring' \
          reflector.v1.k8s.emberstack.com/reflection-auto-enabled=true \
          'reflector.v1.k8s.emberstack.com/reflection-auto-namespaces=trakrf-preview,trakrf-prod,monitoring' \
          -o yaml \
      | kubectl apply -f -
    echo "trakrf-id-origin-tls applied in trakrf-system; reflector will mirror to trakrf-preview/trakrf-prod/monitoring."

# Print the edge demo Cloudflare Tunnel token (TRA-957). Pipe into the box's
# platform/deploy/edge/.env as TUNNEL_TOKEN. Sensitive — don't commit/log.
tunnel-token:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/ops-lib.sh
    require_tf_env
    tofu -chdir=terraform/cloudflare output -raw demo_tunnel_token

# Plan and apply AWS infrastructure (Route53, EKS)
aws: (_backend-conf "terraform/aws")
    @echo "Planning AWS infrastructure..."
    @tofu -chdir=terraform/aws init -backend-config=backend.conf
    @tofu -chdir=terraform/aws plan -out=tfplan
    @tofu -chdir=terraform/aws apply tfplan

# Plan and apply Azure infrastructure (AKS, ACR, Azure DNS)
azure: (_backend-conf "terraform/azure")
    @echo "Planning Azure infrastructure..."
    @tofu -chdir=terraform/azure init -backend-config=backend.conf
    @tofu -chdir=terraform/azure plan -out=tfplan
    @tofu -chdir=terraform/azure apply tfplan

# Plan and apply GCP infrastructure (GKE, Cloud DNS, Artifact Registry)
gcp: (_backend-conf "terraform/gcp")
    @echo "Planning GCP infrastructure..."
    @tofu -chdir=terraform/gcp init -backend-config=backend.conf
    @tofu -chdir=terraform/gcp plan -out=tfplan
    @tofu -chdir=terraform/gcp apply tfplan

# List objects in the R2 terraform state bucket
s3-ls:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/ops-lib.sh
    require_tf_env
    aws s3 ls s3://tf-state --endpoint-url "{{r2_endpoint}}" --profile cloudflare-r2

# Fetch AKS kubeconfig via az CLI, convert to azurecli auth (needs kubelogin)
aks-creds:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/ops-lib.sh
    require_tf_env
    RG=$(tofu -chdir=terraform/azure output -raw resource_group_name)
    CLUSTER=$(tofu -chdir=terraform/azure output -raw cluster_name)
    az aks get-credentials --resource-group "$RG" --name "$CLUSTER" --overwrite-existing
    kubelogin convert-kubeconfig -l azurecli
    kubectl config use-context "$CLUSTER"

# Authenticate to GCP and point kubectl at the GKE cluster — zero to ready.
#
# Uses the browserless flow: it prints a URL, you open it anywhere (phone,
# laptop, any browser), and paste the verification code back at the prompt.
# `--update-adc` refreshes Application Default Credentials in the same step,
# so no separate `gcloud auth application-default login` is needed.
#
# Skips re-authentication if credentials are already valid; FORCE=1 overrides.
gcp-auth:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "${FORCE:-0}" != "1" ] \
       && gcloud auth print-access-token >/dev/null 2>&1 \
       && [ -f "$HOME/.config/gcloud/application_default_credentials.json" ]; then
        echo "✅ Already authenticated as $(gcloud config get-value account 2>/dev/null), ADC present."
        echo "   Re-run with FORCE=1 to re-authenticate."
    else
        gcloud auth login --no-launch-browser --update-adc
    fi
    gcloud container clusters get-credentials {{ gke_cluster }} \
        --zone {{ gcp_zone }} --project {{ gcp_project }}
    kubectl config use-context {{ gke_context }}
    echo "✅ kubectl context: {{ gke_context }}"

# Preflight: is this machine ready to operate the cluster? Detect-only —
# never authenticates, never mutates. Prints the fix for anything it finds.
ops-check:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0

    acct=$(gcloud config get-value account 2>/dev/null || true)
    if [ -n "$acct" ] && gcloud auth print-access-token >/dev/null 2>&1; then
        echo "✅ gcloud authenticated as $acct"
    else
        echo "❌ gcloud not authenticated  → run: just gcp-auth"
        rc=1
    fi

    if [ -f "$HOME/.config/gcloud/application_default_credentials.json" ]; then
        echo "✅ ADC present"
    else
        echo "❌ ADC missing               → run: just gcp-auth"
        rc=1
    fi

    ctx=$(kubectl config current-context 2>/dev/null || true)
    if [ "$ctx" = "{{ gke_context }}" ]; then
        echo "✅ kubectl context {{ gke_context }}"
    else
        echo "❌ kubectl context is '${ctx:-<none>}' → run: just gcp-auth"
        rc=1
    fi

    for ns in trakrf-preview trakrf-prod; do
        reachable=0
        for _ in 1 2 3; do
            if kubectl get ns "$ns" >/dev/null 2>&1; then reachable=1; break; fi
            sleep 2
        done
        if [ "$reachable" = "1" ]; then
            echo "✅ namespace $ns reachable"
        else
            echo "❌ namespace $ns unreachable after 3 tries → see docs/ops.md (Troubleshooting)"
            rc=1
        fi
    done

    exit $rc

# Point kubectl at the GKE cluster using the coordinates above (no tofu, no R2).
# Assumes you are already authenticated — run `just gcp-auth` if not.
gke-creds:
    @gcloud container clusters get-credentials {{ gke_cluster }} \
        --zone {{ gcp_zone }} --project {{ gcp_project }}
    @kubectl config use-context {{ gke_context }}

# Install CNPG operator (direct helm — stays out of ArgoCD, CRD chicken-and-egg)
cnpg-bootstrap CLUSTER:
    @echo "Adding cnpg Helm repo..."
    @helm repo add cnpg https://cloudnative-pg.github.io/charts
    @helm repo update cnpg
    @echo "Installing cloudnative-pg operator ({{CLUSTER}}) into cnpg-system..."
    @helm upgrade --install cnpg cnpg/cloudnative-pg \
      --version 0.28.* \
      --namespace cnpg-system --create-namespace \
      -f helm/cnpg/values.yaml \
      -f helm/cnpg/values-{{CLUSTER}}.yaml
    @echo "Waiting for operator to be ready..."
    @kubectl rollout status deployment/cnpg-cloudnative-pg -n cnpg-system --timeout=120s

# Per-env CNPG role credential Secrets.
#
# Each Cluster (preview, prod) holds the same role names (trakrf-app,
# trakrf-migrate) and references the same Secret names (trakrf-app-credentials,
# trakrf-migrate-credentials) — the K8s namespace is what disambiguates them.
#
# Both env Secrets live natively in their cluster's namespace
# (trakrf-preview / trakrf-prod). No reflector annotations — the prod Cluster
# is now co-located in trakrf-prod, so the cross-namespace mirror that the
# shared-cluster topology needed is gone.
#
# Passwords come from .env.local using openssl rand -hex (per
# feedback_db_password_alphabet — base64 / + chars break URL DSNs).

# Apply CNPG role credential Secrets (both envs native, no reflector)
db-secrets:
    @kubectl create namespace trakrf-preview --dry-run=client -o yaml | kubectl apply -f -
    @kubectl create namespace trakrf-prod --dry-run=client -o yaml | kubectl apply -f -
    @test -n "${TRAKRF_APP_DB_PASSWORD_PREVIEW:-}" || { echo "ERROR: TRAKRF_APP_DB_PASSWORD_PREVIEW not set in .env.local"; exit 1; }
    @test -n "${TRAKRF_APP_DB_PASSWORD_PROD:-}" || { echo "ERROR: TRAKRF_APP_DB_PASSWORD_PROD not set in .env.local"; exit 1; }
    @test -n "${TRAKRF_MIGRATE_DB_PASSWORD_PREVIEW:-}" || { echo "ERROR: TRAKRF_MIGRATE_DB_PASSWORD_PREVIEW not set in .env.local"; exit 1; }
    @test -n "${TRAKRF_MIGRATE_DB_PASSWORD_PROD:-}" || { echo "ERROR: TRAKRF_MIGRATE_DB_PASSWORD_PROD not set in .env.local"; exit 1; }
    @just _db-secret app     trakrf-preview "${TRAKRF_APP_DB_PASSWORD_PREVIEW}"
    @just _db-secret app     trakrf-prod    "${TRAKRF_APP_DB_PASSWORD_PROD}"
    @just _db-secret migrate trakrf-preview "${TRAKRF_MIGRATE_DB_PASSWORD_PREVIEW}"
    @just _db-secret migrate trakrf-prod    "${TRAKRF_MIGRATE_DB_PASSWORD_PROD}"
    @echo "Secrets applied. Both envs native in their namespaces (no reflector)."

# Helper: create one CNPG role credential Secret.
#   ROLE : "app" | "migrate"   → produces Secret `trakrf-<ROLE>-credentials`
#   NS   : namespace to create the Secret in
#   PW   : password
_db-secret ROLE NS PW:
    @kubectl create secret generic trakrf-{{ROLE}}-credentials -n {{NS}} \
      --from-literal=username=trakrf-{{ROLE}} \
      --from-literal=password="{{PW}}" \
      --dry-run=client -o yaml | kubectl apply -f -

# Create the Mosquitto broker auth Secret in trakrf-system with reflector
# annotations so it mirrors into trakrf-preview / trakrf-prod. Run BEFORE the
# trakrf-mosquitto broker pods come up — they mount this Secret for the loopback
# password_file + the exporter (and trakrf-backend subscriber) env credentials.
#
# Requires in .env.local:
#   MOSQUITTO_USER       e.g. trakrf-mqtt (arbitrary shared broker username)
#   MOSQUITTO_PASSWORD   generate with `openssl rand -hex 32`
#                        (base64 has /+ which breaks URL-composed DSNs;
#                        see feedback_db_password_alphabet)
# Idempotent. Re-running rotates the Secret; Stakater Reloader bounces both
# env pods automatically (the trakrf-mosquitto Deployment carries the
# `reloader.stakater.com/auto: "true"` annotation).
mosquitto-secrets:
    @kubectl create namespace trakrf-system --dry-run=client -o yaml | kubectl apply -f -
    @kubectl create namespace trakrf-preview --dry-run=client -o yaml | kubectl apply -f -
    @kubectl create namespace trakrf-prod --dry-run=client -o yaml | kubectl apply -f -
    @test -n "${MOSQUITTO_USER:-}" || { echo "ERROR: MOSQUITTO_USER not set in .env.local"; exit 1; }
    @test -n "${MOSQUITTO_PASSWORD:-}" || { echo "ERROR: MOSQUITTO_PASSWORD not set in .env.local"; exit 1; }
    @# Use a throwaway eclipse-mosquitto container so we don't depend on a host
    @# mosquitto_passwd binary. Builds the hashed password_file for the shared
    @# trakrf-mqtt user, then folds it into a Secret alongside the literal creds.
    @PASSWD_FILE=$(docker run --rm eclipse-mosquitto:2.0.21 sh -c \
      "mosquitto_passwd -b -c /tmp/passwd '${MOSQUITTO_USER}' '${MOSQUITTO_PASSWORD}' >/dev/null; \
       cat /tmp/passwd") && \
     kubectl create secret generic trakrf-mosquitto-auth -n trakrf-system \
       --from-literal=passwd="$PASSWD_FILE" \
       --from-literal=username="${MOSQUITTO_USER}" \
       --from-literal=password="${MOSQUITTO_PASSWORD}" \
       --dry-run=client -o yaml | kubectl apply -f -
    @kubectl annotate --overwrite secret trakrf-mosquitto-auth -n trakrf-system \
      reflector.v1.k8s.emberstack.com/reflection-allowed=true \
      reflector.v1.k8s.emberstack.com/reflection-auto-enabled=true \
      reflector.v1.k8s.emberstack.com/reflection-auto-namespaces=trakrf-preview,trakrf-prod
    @echo "Mosquitto auth Secret applied. Reflector mirrors to trakrf-{preview,prod}."

# Install ArgoCD via Helm + install trakrf-root app-of-apps for the given cluster
argocd-bootstrap CLUSTER:
    @echo "Adding ArgoCD Helm repo..."
    @helm repo add argo https://argoproj.github.io/argo-helm
    @helm repo update argo
    @echo "Installing ArgoCD into argocd namespace ({{CLUSTER}})..."
    @helm upgrade --install argocd argo/argo-cd \
      --namespace argocd --create-namespace \
      -f argocd/bootstrap/values.yaml \
      -f argocd/bootstrap/values-{{CLUSTER}}.yaml
    @echo "Waiting for ArgoCD server to be ready..."
    @kubectl rollout status deployment/argocd-server -n argocd --timeout=120s
    @echo "Applying AppProject..."
    @kubectl apply -f argocd/projects/trakrf.yaml
    @echo "Installing trakrf-root app-of-apps..."
    @./scripts/apply-root-app.sh {{CLUSTER}}
    @echo "ArgoCD bootstrap complete. Run 'just argocd-password' for the admin password."

# Run scripted smoke preconditions (see scripts/smoke-aks.sh)
smoke-aks:
    @./scripts/smoke-aks.sh

# Run scripted smoke preconditions (see scripts/smoke-gke.sh)
smoke-gke:
    @./scripts/smoke-gke.sh

# Fetch ArgoCD initial admin password
argocd-password:
    @kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d && echo

# Port-forward ArgoCD UI to :8080 (all interfaces)
argocd-ui:
    @echo "ArgoCD UI at https://<host-ip>:8080 (admin / <just argocd-password>)"
    @kubectl port-forward svc/argocd-server -n argocd 8080:443 --address 0.0.0.0

# Sync + health for every ArgoCD Application.
argo-status:
    @kubectl get applications -n argocd \
        -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:'.status.sync.revision'

# Request a sync of one ArgoCD Application. Prompts for everything except
# *-preview apps: *-prod apps AND the cluster-scoped apps (traefik,
# cert-manager, argocd, ...) that carry production traffic for both
# environments despite not being named *-prod.
# The argocd CLI is not installed here; this patches the Application's
# operation field, which is what the CLI does under the hood.
#   just argo-sync trakrf-backend-preview
argo-sync APP:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/ops-lib.sh
    if ! kubectl -n argocd get application "{{ APP }}" >/dev/null 2>&1; then
        echo "ERROR: no ArgoCD Application named '{{ APP }}' — see: just argo-status" >&2
        exit 1
    fi
    case "{{ APP }}" in
        *-preview) ;;
        *) confirm_prod prod "argocd sync {{ APP }}" ;;
    esac
    kubectl -n argocd patch application "{{ APP }}" --type merge \
        -p '{"operation":{"initiatedBy":{"username":"just-argo-sync"},"sync":{"revision":"HEAD"}}}'
    echo "→ sync requested; watch with: just argo-status"

# Install kube-prometheus-stack into monitoring namespace (direct helm, not ArgoCD)
monitoring-bootstrap CLUSTER:
    @echo "Adding prometheus-community Helm repo..."
    @helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    @helm repo update prometheus-community
    @echo "Installing kube-prometheus-stack ({{CLUSTER}}) into monitoring namespace..."
    @helm upgrade --install kube-prometheus-stack \
      prometheus-community/kube-prometheus-stack \
      --version 83.4.1 \
      --namespace monitoring --create-namespace \
      -f helm/monitoring/values.yaml \
      -f helm/monitoring/values-{{CLUSTER}}.yaml
    @echo "Waiting for Grafana to be ready..."
    @kubectl rollout status deployment/kube-prometheus-stack-grafana -n monitoring --timeout=300s
    @echo "Building dashboards ConfigMap from helm/monitoring/dashboards/..."
    @kubectl create configmap kube-prometheus-stack-dashboards \
      --namespace monitoring \
      --from-file=helm/monitoring/dashboards/ \
      --dry-run=client -o yaml \
      | kubectl label --local -f - grafana_dashboard=1 -o yaml --dry-run=client \
      | kubectl apply --server-side --force-conflicts -f -
    @echo "Applying cluster-agnostic manifests (CNPG ServiceMonitor, dashboards)..."
    @kubectl apply --server-side --force-conflicts -n monitoring -f helm/monitoring/manifests/
    @echo "Applying {{CLUSTER}}-specific manifests (Grafana IngressRoute with {{CLUSTER}} host)..."
    @kubectl apply --server-side --force-conflicts -n monitoring -f helm/monitoring/manifests-{{CLUSTER}}/

# Fetch Grafana admin password
grafana-password:
    @kubectl get secret kube-prometheus-stack-grafana -n monitoring \
      -o jsonpath='{.data.admin-password}' | base64 -d && echo

# Port-forward Grafana UI to :3000 on all interfaces
grafana-ui:
    @echo "Grafana at http://<host-ip>:3000 (admin / $(just grafana-password))"
    @kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80 --address 0.0.0.0

# Port-forward Prometheus UI to :9090 on all interfaces
prometheus-ui:
    @echo "Prometheus at http://<host-ip>:9090"
    @kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090 --address 0.0.0.0

# Restore proof: pull the latest pg_dump for ENV from GCS, restore it
# into a scratch database on that env's live CNPG cluster, run a sanity
# query, drop the scratch database. Requires:
#   - `just gcp-auth` (logs in and refreshes ADC in one step — `gcloud storage`
#     needs ADC, which `gcloud auth login --update-adc` already provides)
#   - kubectl context pointed at the GKE cluster
#
# The bucket is read from the live Cluster spec rather than a tofu output,
# so this needs no .env.local and no initialized R2 backend — and it reports
# where the cluster actually writes, catching drift instead of masking it.
#
# ENV is required: this recipe can mutate prod, so it must not default.
#
# Usage:
#   just db-restore-test preview
#   just db-restore-test prod
db-restore-test ENV:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/ops-lib.sh
    require_env "{{ ENV }}"
    ns="trakrf-{{ ENV }}"
    cluster="trakrf-db-{{ ENV }}"

    confirm_prod "{{ ENV }}" "restore proof — creates and drops a scratch DB on the live ${cluster} primary"

    # Bucket comes from the live Cluster's barman config, not tofu: no
    # backend init, no .env.local, and it is authoritative for this cluster.
    bucket=$(kubectl -n "$ns" get cluster "$cluster" \
      -o jsonpath='{.spec.backup.barmanObjectStore.destinationPath}')
    bucket=${bucket#gs://}
    test -n "$bucket" || { echo "could not resolve backup bucket from cluster ${cluster} in ${ns}"; exit 1; }

    # Path layout is set by helm/trakrf-db/templates/backup-cronjob.yaml:
    #   gs://<bucket>/<cluster>/dump/YYYY/MM/DD/HHMM.pgdump
    # Zero-padded, so lexical sort puts the newest last.
    echo "Looking for latest dump in gs://${bucket}/${cluster}/dump/..."
    # `gcloud storage ls` EXITS 1 when the prefix matches nothing ("One or
    # more URLs matched no objects"), and pipefail propagates that through
    # `sort | tail`. A bare `latest=$(...)` therefore aborts the recipe under
    # `set -e` before any `test -n "$latest"` guard can run, so the friendly
    # message naming the bucket and prefix was unreachable. Capture the
    # pipeline's status in the `if` instead, which keeps it reachable while
    # still covering the "exited 0 but printed nothing" case.
    # gcloud's own stderr is left visible above this message, so a real
    # failure (expired ADC, wrong project) is still distinguishable.
    if ! latest=$(gcloud storage ls "gs://${bucket}/${cluster}/dump/**/*.pgdump" | sort | tail -1) \
       || [ -z "$latest" ]; then
      echo "no dumps found in gs://${bucket}/${cluster}/dump/ (or the listing itself failed — see any gcloud error above)" >&2
      exit 1
    fi
    echo "Latest dump: $latest"

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    gcloud storage cp "$latest" "$tmp/dump.pgdump"
    ls -la "$tmp/dump.pgdump"

    # `kubectl exec ... psql -U postgres` on the CNPG primary uses peer
    # auth via the unix socket — no password needed.
    pg_pod=$(cnpg_primary_pod "$ns")
    scratch="trakrf_restore_test_$(date -u +%s)"
    scratch_created=0

    # Best-effort cleanup on ANY exit once the scratch DB exists, so a
    # mid-run failure (pg_restore, timescaledb_post_restore, the sanity
    # query) never leaves it behind on the live primary — including prod,
    # where it would otherwise silently consume PVC space on a
    # single-instance cluster. Installed only after CREATE DATABASE
    # succeeds, so an earlier abort (bucket resolution, download) never
    # tries to drop a database that was never created.
    #
    # WITH (FORCE) (PG 13+; this cluster runs PG 17) drops it even if a
    # session is still attached. The drop itself is best-effort: a
    # failure here only warns, it must never mask the recipe's real exit
    # status, which is captured up front and re-asserted via `exit`.
    cleanup() {
        local status=$?
        rm -rf "$tmp"
        if [ "$scratch_created" = "1" ]; then
            echo "Dropping scratch DB ${scratch}..."
            kubectl -n "$ns" exec "${pg_pod}" -- \
              psql -U postgres -v ON_ERROR_STOP=1 \
                -c "DROP DATABASE IF EXISTS \"${scratch}\" WITH (FORCE)" \
              || echo "WARNING: failed to drop scratch DB ${scratch} on ${cluster} in ${ns} — drop it manually" >&2
        fi
        exit "$status"
    }

    echo "Creating scratch DB ${scratch} on ${pg_pod}..."
    # Create the scratch DB with the timescaledb extension pre-installed,
    # then bracket pg_restore with timescaledb_pre_restore / _post_restore.
    # Without that bracketing, pg_restore emits "ONLY option not supported
    # on hypertable operations" while replaying foreign-key constraints
    # and exits non-zero — the standard Timescale logical-restore pattern.
    # See https://docs.timescale.com/self-hosted/latest/backup-and-restore/logical-backup/
    kubectl -n "$ns" exec "${pg_pod}" -- \
      psql -U postgres -v ON_ERROR_STOP=1 \
        -c "CREATE DATABASE \"${scratch}\""
    scratch_created=1
    trap cleanup EXIT
    kubectl -n "$ns" exec "${pg_pod}" -- \
      psql -U postgres -d "${scratch}" -v ON_ERROR_STOP=1 \
        -c "CREATE EXTENSION IF NOT EXISTS timescaledb" \
        -c "SELECT timescaledb_pre_restore()"

    echo "Restoring dump into ${scratch}..."
    kubectl -n "$ns" exec -i "${pg_pod}" -- \
      pg_restore --no-owner --no-privileges -U postgres -d "${scratch}" \
      < "$tmp/dump.pgdump"

    echo "Running timescaledb_post_restore()..."
    kubectl -n "$ns" exec "${pg_pod}" -- \
      psql -U postgres -d "${scratch}" -v ON_ERROR_STOP=1 \
        -c "SELECT timescaledb_post_restore()"

    echo "Sanity check — schema + table row counts:"
    # Hypertables are listed SEPARATELY, with exact counts. A TimescaleDB
    # hypertable keeps its rows in chunk relations under _timescaledb_internal,
    # so the parent relation reports n_live_tup = 0 forever. Listing the
    # parents alongside the plain tables therefore printed "asset_scans 0"
    # directly above a PASS, which an operator reads as "the time-series data
    # did not come back" when in fact ~16.8M rows did. Splitting them out is
    # the difference between a report and a misleading report.
    kubectl -n "$ns" exec "${pg_pod}" -- \
      psql -U postgres -d "${scratch}" -v ON_ERROR_STOP=1 \
        -c "\dn" \
        -c "WITH ht AS (
                SELECT format('%I.%I', hypertable_schema, hypertable_name) AS qualname,
                       hypertable_name AS relname,
                       format('%I.%I', hypertable_schema, hypertable_name)::regclass::oid AS reloid
                  FROM timescaledb_information.hypertables
                 WHERE hypertable_schema = 'trakrf'
            )
            SELECT 'hypertable' AS kind, ht.relname, ht.qualname AS relation,
                   (xpath('/row/c/text()',
                     query_to_xml(format('SELECT count(*) AS c FROM %s', ht.qualname),
                                  false, true, '')))[1]::text::bigint AS rows
              FROM ht
            UNION ALL
            SELECT 'table', s.relname, format('%I.%I', s.schemaname, s.relname),
                   GREATEST(s.n_live_tup, 0)
              FROM pg_stat_user_tables s
             WHERE s.schemaname = 'trakrf'
               AND s.relid NOT IN (SELECT reloid FROM ht)
             ORDER BY 1, 2;"

    # Emptiness gate — printing rowcounts is not proving them. Without this,
    # a dump that restores cleanly but carries no data (schema-only dump, a
    # dump of the wrong database, a truncated object) produces an empty
    # result table and still exits 0 with "Restore proof complete", which is
    # exactly the hollow-success bug the sibling PITR recipe already closed.
    #
    # `pg_stat_user_tables.n_live_tup` IS the right source for the PLAIN
    # tables here, unlike in db-restore-pitr-test: this data arrives via
    # pg_restore INSERTs into a live, running cluster, so the statistics
    # collector genuinely counts the rows. (In the PITR recipe the data
    # arrives as a physical base backup that does not carry collector state,
    # so it must read catalog data — pg_class.reltuples plus
    # approximate_row_count() — there. The asymmetry is deliberate — do not
    # unify the two queries.)
    #
    # HYPERTABLES must be counted separately, and that is the whole point of
    # TRA-1059. trakrf.asset_scans and trakrf.tag_scans are TimescaleDB
    # hypertables whose rows live in chunk relations under
    # _timescaledb_internal, so the hypertable PARENT reports 0 in BOTH
    # n_live_tup and reltuples. Summing only the parents scored preview at
    # ~242k rows when the database actually held ~16.8M — about 1.4% of the
    # truth — so a restore that lost EVERY chunk would still have passed this
    # gate. That is the same false-green class the gate exists to prevent, one
    # layer deeper, and the data it was hiding is the product's core
    # time-series data: the single most important thing to verify.
    #
    # Summing chunk relations' n_live_tup was the cheap candidate fix and it
    # undercounts too: tag_scans is compressed on preview (5 of 8 chunks), and
    # a compressed chunk's relation stores roughly one row per 1000 source
    # rows. Exact count(*) is both honest and cheap here — measured 1.2s for
    # 16.6M rows on the preview cluster, a parallel seq scan — so this gate
    # counts hypertables exactly. query_to_xml is the standard pure-SQL way to
    # run a dynamic count without creating a helper function in the scratch DB.
    #
    # Hypertables are DISCOVERED from timescaledb_information.hypertables and
    # never hardcoded, so this keeps working across preview (28 tables) and
    # prod (15 tables, 28 migrations behind) and across any future migration
    # that adds or removes a hypertable. The timescaledb extension is already a
    # hard dependency of this recipe (see the pre_restore/post_restore
    # bracketing above), so leaning on its catalog views adds no new one.
    #
    # Judged on the trakrf schema AS A WHOLE (total tables + total rows),
    # never per-table, so a legitimately empty table (prod's tag_scans is 0
    # rows with 0 chunks today; ingestion gap TRA-900) can never trip a false
    # alarm, and so the gate stays schema-agnostic across both envs.
    #
    # "The check could not RUN" and "the restore is genuinely EMPTY" are
    # different findings and must never be reported as the same thing:
    # capture first, check the exit status, validate the shape, and only
    # then judge emptiness. (`read -r a b <<< "$(cmd)"` cannot do this —
    # `set -e` does not fire on a command substitution feeding a here-string,
    # so a dropped connection would be announced as an empty restore.)
    #
    # This runs BEFORE the DROP DATABASE below, and a failure here still
    # routes through the cleanup trap, so the scratch DB is dropped either
    # way and the real exit status is preserved.
    if ! gate_out=$(kubectl -n "$ns" exec "${pg_pod}" -- \
      psql -U postgres -d "${scratch}" -v ON_ERROR_STOP=1 -t -A -F' ' \
        -c "WITH ht AS (
                SELECT format('%I.%I', hypertable_schema, hypertable_name) AS qualname,
                       format('%I.%I', hypertable_schema, hypertable_name)::regclass::oid AS reloid
                  FROM timescaledb_information.hypertables
                 WHERE hypertable_schema = 'trakrf'
            ), ht_rows AS (
                SELECT count(*) AS n_tables,
                       coalesce(sum((xpath('/row/c/text()',
                         query_to_xml(format('SELECT count(*) AS c FROM %s', qualname),
                                      false, true, '')))[1]::text::bigint), 0) AS n_rows
                  FROM ht
            ), plain AS (
                SELECT count(*) AS n_tables,
                       coalesce(sum(GREATEST(s.n_live_tup, 0)), 0) AS n_rows
                  FROM pg_stat_user_tables s
                 WHERE s.schemaname = 'trakrf'
                   AND s.relid NOT IN (SELECT reloid FROM ht)
            )
            SELECT plain.n_tables, plain.n_rows, ht_rows.n_tables, ht_rows.n_rows
              FROM plain, ht_rows;"); then
      echo >&2
      echo "ERROR: INCONCLUSIVE — the emptiness sanity-check query could not be RUN." >&2
      echo "The restore itself may be perfectly fine; this failure is about the check," >&2
      echo "not about the data. Do NOT read this as an empty restore." >&2
      echo "The scratch DB is dropped on exit, so re-run the proof to re-check." >&2
      exit 1
    fi

    # A zero exit with empty or unparseable output is likewise "could not
    # determine", not "empty".
    read -r plain_tables plain_rows ht_tables ht_rows <<< "$gate_out"
    if ! [[ "$plain_tables" =~ ^[0-9]+$ ]] || ! [[ "$plain_rows" =~ ^[0-9]+$ ]] \
       || ! [[ "$ht_tables" =~ ^[0-9]+$ ]] || ! [[ "$ht_rows" =~ ^[0-9]+$ ]]; then
      echo >&2
      echo "ERROR: INCONCLUSIVE — the emptiness sanity-check query returned no usable output." >&2
      echo "It exited 0 but did not produce the expected" >&2
      echo "'<plain_tables> <plain_rows> <hypertables> <hypertable_rows>' quad, so the" >&2
      echo "check could not be evaluated. This is NOT evidence of an empty restore." >&2
      echo "Raw output was: [${gate_out}]" >&2
      exit 1
    fi

    # Totals decide the verdict; the split is what the operator needs to see.
    # A hypertable row count of 0 while plain tables are populated is the exact
    # shape of "the restore lost every chunk", so it must never hide inside a
    # single aggregate number again.
    restored_table_count=$(( plain_tables + ht_tables ))
    restored_live_rows=$(( plain_rows + ht_rows ))

    echo
    echo "==== emptiness check: ${restored_table_count} tables in trakrf schema (${plain_tables} plain + ${ht_tables} hypertable) ===="
    echo "====   ${restored_live_rows} total rows: ${plain_rows} in plain tables + ${ht_rows} in hypertable chunks (exact count) ===="
    if [ "$restored_table_count" -eq 0 ] || [ "$restored_live_rows" -eq 0 ]; then
      echo "FAIL: the check RAN and the restored trakrf schema is EMPTY (0 tables, or 0 total rows across all tables and hypertables)." >&2
      echo "This is not a passing restore proof — the dump did not bring back real data." >&2
      echo "Dump under test was: ${latest}" >&2
      exit 1
    fi
    echo "PASS: trakrf schema restored with ${restored_table_count} tables and real (non-zero) data,"
    echo "      including ${ht_rows} time-series rows across ${ht_tables} hypertable(s)."

    echo "Dropping scratch DB ${scratch}..."
    kubectl -n "$ns" exec "${pg_pod}" -- \
      psql -U postgres -v ON_ERROR_STOP=1 -c "DROP DATABASE \"${scratch}\""
    scratch_created=0

    echo "Restore proof complete for {{ ENV }} (${cluster} in ${ns})."

# Manually trigger an ad-hoc CNPG Backup CR against ENV's cluster.
# Useful for first-install verification (don't wait for the scheduled
# run) or for taking a guaranteed-fresh base backup before a risky
# operation.
#
# Usage:
#   just db-pitr-trigger-base preview
#   just db-pitr-trigger-base prod
db-pitr-trigger-base ENV:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/ops-lib.sh
    require_env "{{ ENV }}"
    ns="trakrf-{{ ENV }}"
    cluster="trakrf-db-{{ ENV }}"

    confirm_prod "{{ ENV }}" "trigger an ad-hoc base backup on the live ${cluster}"

    # kubectl apply requires a fixed name; embed a timestamp for uniqueness.
    name="${cluster}-manual-$(date -u +%Y%m%d%H%M%S)"
    kubectl -n "$ns" apply -f - <<EOF
    apiVersion: postgresql.cnpg.io/v1
    kind: Backup
    metadata:
      name: ${name}
      namespace: ${ns}
    spec:
      cluster:
        name: ${cluster}
      method: barmanObjectStore
    EOF
    echo "Backup CR ${name} submitted. Watch with: kubectl -n ${ns} get backup -w"

# Proves CNPG PITR by spinning up a scratch Cluster that recovers ENV's
# barman object store, optionally to a specific point in time. The scratch
# cluster always uses the fixed name `trakrf-restore-test` in trakrf-system
# so the static WI binding in terraform/gcp/cnpg_backups.tf fits — only the
# recovery source (serverName) is per-env.
#
# Does NOT touch the live cluster: it reads the object store only. Safe to
# run against prod without a confirmation gate.
#
# Idempotent: pre-deletes any leftover scratch cluster before applying.
#
# Recovering to latest (the default, no TARGET_TIME) replays every WAL
# segment written since the source's last base backup, so how long this
# takes depends entirely on how much WAL has piled up since then — see the
# RESTORE_READY_TIMEOUT reasoning further down. Two ways to make a preview
# run fast instead of slow-but-honest:
#   - Run it shortly after the daily 09:30 UTC scheduled base backup, while
#     little WAL has accumulated yet.
#   - Pass a TARGET_TIME close to the most recent base backup's timestamp:
#     CNPG picks the closest backup completed before that target and stops
#     replay AT the target, so this bounds replay instead of chasing
#     latest — it does not depend on how much WAL has piled up since.
# Taking a fresh base backup first (`just db-pitr-trigger-base`) is NOT a
# shortcut: that recipe itself takes ~18 minutes to complete.
#
# The Ready-wait timeout is overridable via RESTORE_READY_TIMEOUT — see
# below — rather than a third positional argument, so it can't collide
# with ENV/TARGET_TIME ordering.
#
# Usage:
#   just db-restore-pitr-test preview
#   just db-restore-pitr-test prod
#   just db-restore-pitr-test prod "2026-05-27T10:30:00Z"
#   RESTORE_READY_TIMEOUT=3h just db-restore-pitr-test preview
db-restore-pitr-test ENV TARGET_TIME="":
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/ops-lib.sh
    require_env "{{ ENV }}"
    src_ns="trakrf-{{ ENV }}"
    src_cluster="trakrf-db-{{ ENV }}"
    scratch=trakrf-restore-test
    ns=trakrf-system

    # Bucket and backup GSA come from the live env cluster + its backup KSA,
    # not tofu — no backend init required.
    bucket=$(kubectl -n "$src_ns" get cluster "$src_cluster" \
      -o jsonpath='{.spec.backup.barmanObjectStore.destinationPath}')
    bucket=${bucket#gs://}
    test -n "$bucket" || { echo "could not resolve backup bucket from cluster ${src_cluster} in ${src_ns}"; exit 1; }

    gsa=$(kubectl -n "$src_ns" get sa cnpg-backups \
      -o jsonpath='{.metadata.annotations.iam\.gke\.io/gcp-service-account}')
    test -n "$gsa" || { echo "could not resolve backup GSA from sa/cnpg-backups in ${src_ns}"; exit 1; }

    # Storage size tracks the SOURCE cluster's provisioned size, not a
    # literal. A hardcoded scratch size silently rots as the source database
    # grows: preview's trakrf DB (~6GB) no longer fits in a 5Gi literal,
    # which is exactly the ENOSPC crashloop this recipe hit in production.
    storage_size=$(kubectl -n "$src_ns" get cluster "$src_cluster" \
      -o jsonpath='{.spec.storage.size}')
    test -n "$storage_size" || { echo "could not resolve storage size from cluster ${src_cluster} in ${src_ns}"; exit 1; }

    # Postgres image likewise tracks the SOURCE cluster, not a literal, for
    # the same reason the size does. A physical base backup can only be
    # replayed by the same PG major version that wrote it: bump
    # helm/trakrf-db/values.yaml to a PG 18 image and a pinned PG 17 scratch
    # cluster refuses to start with "database files are incompatible with
    # server", never reaches Ready, burns the full 20m timeout, and the
    # cleanup trap deletes the evidence. Deriving it means the scratch
    # cluster follows the source across any future major-version bump.
    image_name=$(kubectl -n "$src_ns" get cluster "$src_cluster" \
      -o jsonpath='{.spec.imageName}')
    test -n "$image_name" || { echo "could not resolve imageName from cluster ${src_cluster} in ${src_ns}"; exit 1; }
    echo "Recovering ${src_cluster} from gs://${bucket}/${src_cluster} as ${gsa} (storage ${storage_size}, image ${image_name})"

    echo "Pre-cleanup: deleting any leftover ${scratch} cluster..."
    kubectl -n "$ns" delete cluster "$scratch" --ignore-not-found --wait=true

    target_block=""
    if [[ -n "{{ TARGET_TIME }}" ]]; then
      target_block=$'\n      recoveryTarget:\n        targetTime: "{{ TARGET_TIME }}"'
    fi

    # Best-effort cleanup on ANY exit once the scratch Cluster has actually
    # been applied, so a mid-run failure (Ready timeout, either psql exec)
    # never leaves it running in trakrf-system — holding a PVC and node
    # capacity — until someone notices or the next invocation's pre-delete
    # step happens to clean it up. Installed only after `kubectl apply`
    # succeeds, so an earlier abort (bucket/GSA resolution) never tries to
    # delete a cluster that was never created.
    #
    # --wait=false here (fire-and-forget): a CNPG Cluster delete can take a
    # while to fully drain, and a trap that blocks for minutes on an
    # already-failed run just compounds the problem. The success path below
    # still does its normal --wait=true teardown so the operator sees a
    # clean finish; this trap only has to fire on the failure paths, where
    # "delete requested" is enough. The drop itself is best-effort: a
    # failure here only warns, it must never mask the recipe's real exit
    # status, which is captured up front and re-asserted via `exit`.
    scratch_applied=0
    cleanup() {
        local status=$?
        if [ "$scratch_applied" = "1" ]; then
            echo "Cleaning up scratch cluster ${scratch} (best-effort, not waiting)..."
            kubectl -n "$ns" delete cluster "$scratch" --ignore-not-found --wait=false \
              || echo "WARNING: failed to delete scratch cluster ${scratch} in ${ns} — delete it manually" >&2
        fi
        exit "$status"
    }

    echo "Applying scratch Cluster ${scratch} pointing at gs://${bucket}/${src_cluster} ..."
    cat <<EOF | kubectl apply -f -
    apiVersion: postgresql.cnpg.io/v1
    kind: Cluster
    metadata:
      name: ${scratch}
      namespace: ${ns}
    spec:
      instances: 1
      imageName: ${image_name}
      storage:
        size: ${storage_size}
        # storageClass is deliberately NOT derived from the source cluster.
        # Sources use premium-rwo-retain (Retain reclaim policy) so a deleted
        # Cluster leaves its PV behind for recovery. This cluster is a
        # throwaway proof torn down on every run, and a retained PV per run
        # would silently accumulate orphaned disks and cost. premium-rwo is
        # the same underlying disk type with Delete reclaim — the intended
        # behaviour here, not an oversight.
        storageClass: premium-rwo
      affinity:
        tolerations:
          - key: kubernetes.io/arch
            operator: Equal
            value: arm64
            effect: NoSchedule
      serviceAccountTemplate:
        metadata:
          annotations:
            iam.gke.io/gcp-service-account: ${gsa}
      bootstrap:
        recovery:
          source: trakrf-db-source${target_block}
      externalClusters:
        - name: trakrf-db-source
          barmanObjectStore:
            destinationPath: gs://${bucket}
            serverName: ${src_cluster}
            googleCredentials:
              gkeEnvironment: true
            wal:
              compression: gzip
    EOF
    scratch_applied=1
    trap cleanup EXIT

    # RESTORE_READY_TIMEOUT overrides how long we wait for the scratch
    # cluster to become Ready. It's an env var, not a third positional
    # arg, so it can't collide with ENV/TARGET_TIME ordering, and it needs
    # no justfile edit to change — same shape as YES=1 for confirm_prod in
    # scripts/ops-lib.sh.
    #
    # Recovering to LATEST replays every WAL segment since the source's
    # last base backup, so wait time scales with how much WAL has piled up
    # since then, not with dataset size. Measured on preview 2026-07-29
    # 22:24 UTC: 1,193 WAL segments / 5.14 GB accumulated in 5h11m since
    # the prior base backup (20260729T171320) — roughly 1 GB/hour, driven
    # by live MQTT scan ingestion. That run did NOT finish inside the
    # previous 20m budget. Base backups run once daily (09:30 UTC), so the
    # worst case is late in the day, just before the next one: close to
    # 24h of accumulation at ~1 GB/hour is on the order of ~24 GB of WAL to
    # fetch and replay, on top of the base backup restore itself — roughly
    # 4-5x the WAL volume of the run that already blew through 20m. 120m
    # is chosen to sit well above a straight-line extrapolation from that
    # measurement, with margin left for base-backup-fetch and instance
    # startup overhead on top of WAL replay. Prod is comparatively instant
    # (15 WAL objects / 5 MB in 13h in the same measurement) and finishes
    # in a few minutes regardless of this default.
    #
    # Must be a duration kubectl understands (e.g. 20m, 90m, 2h). A
    # malformed value must not silently become a zero (immediate timeout)
    # or unbounded wait, so it's validated and falls back to the default
    # — loudly — instead.
    default_ready_timeout="120m"
    ready_timeout="${RESTORE_READY_TIMEOUT:-$default_ready_timeout}"
    if ! [[ "$ready_timeout" =~ ^[0-9]+(s|m|h)$ ]]; then
      echo "WARNING: RESTORE_READY_TIMEOUT='${ready_timeout}' is not a valid duration (expected e.g. 20m, 90m, 2h) — using default ${default_ready_timeout}." >&2
      ready_timeout="$default_ready_timeout"
    fi

    echo "Waiting up to ${ready_timeout} for scratch cluster to become Ready." \
         "Recovery time here scales with how much WAL has accumulated since" \
         "the source's last base backup, not with dataset size: preview takes" \
         "live MQTT scan ingestion and accumulates roughly 1 GB of WAL per" \
         "hour, so late in the day — just before the next 09:30 UTC scheduled" \
         "base backup — a recover-to-latest run can be replaying on the order" \
         "of ~24 GB of WAL. That is a slow-but-progressing restore, not a" \
         "hang. Prod's WAL volume is comparatively negligible and finishes in" \
         "a few minutes. To make a preview run fast instead: run it shortly" \
         "after the 09:30 UTC base backup, or pass a TARGET_TIME close to the" \
         "most recent base backup to bound replay instead of chasing latest" \
         "(see docs/backups.md)."
    if ! kubectl -n "$ns" wait --for=condition=Ready cluster/${scratch} --timeout="${ready_timeout}"; then
      echo "Scratch cluster ${scratch} did not become Ready in time." >&2
      echo "Before the cleanup trap deletes it, inspect the recovery job's logs:" >&2
      echo "  kubectl -n ${ns} logs -l cnpg.io/jobRole=full-recovery --tail=50" >&2
      exit 1
    fi

    pg_pod=$(cnpg_primary_pod "$ns")

    echo
    echo "==== databases in recovered cluster ===="
    kubectl -n "$ns" exec "$pg_pod" -- psql -U postgres -c "\l"

    # NOTE: deliberately NOT pg_stat_user_tables.n_live_tup here. It is a
    # stats-collector counter, not part of the physical backup, and reads 0
    # right after any physical restore until autovacuum/ANALYZE repopulates
    # it — which is why an earlier version of this check reported "all
    # zero" on a restore that had, in fact, fully succeeded. pg_class.reltuples
    # is a regular catalog column updated by ANALYZE via a normal WAL-logged
    # UPDATE, so it IS part of the physical backup/recovery stream and
    # survives a PITR intact (it is an estimate, and -1/NULL for a table
    # that has never been analyzed — not evidence of emptiness by itself).
    #
    # Hypertables are listed SEPARATELY via approximate_row_count(). Their rows
    # live in chunk relations under _timescaledb_internal, so a hypertable
    # PARENT's reltuples is always -1/0 no matter how much data recovered.
    # Listing the parents next to the plain tables printed "asset_scans 0"
    # right above a PASS, which an operator reads as "the time-series data did
    # not come back" when in fact millions of rows did. approximate_row_count()
    # aggregates the chunks' reltuples and consults
    # _timescaledb_catalog.compression_chunk_size for compressed chunks — all
    # ordinary WAL-logged catalog data, so it is as PITR-safe as reltuples
    # itself, and it never scans the heap (measured 0.4s against 16.6M rows).
    echo
    echo "==== trakrf: schema + catalog row-count overview (pg_class.reltuples / approximate_row_count) ===="
    kubectl -n "$ns" exec "$pg_pod" -- \
      psql -U postgres -d trakrf -c "\dn" \
      -c "WITH ht AS (
              SELECT format('%I.%I', hypertable_schema, hypertable_name)::regclass AS rel,
                     hypertable_schema AS schemaname, hypertable_name AS relname
                FROM timescaledb_information.hypertables
               WHERE hypertable_schema = 'trakrf'
          )
          SELECT 'hypertable' AS kind, ht.schemaname, ht.relname,
                 GREATEST(approximate_row_count(ht.rel), 0) AS est_rows
            FROM ht
          UNION ALL
          SELECT 'table', n.nspname, c.relname,
                 CASE WHEN c.reltuples < 0 THEN NULL ELSE c.reltuples::bigint END
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = 'trakrf' AND c.relkind = 'r'
            AND c.oid NOT IN (SELECT rel::oid FROM ht)
          ORDER BY 1, 3;"

    echo
    echo "==== trakrf: exact row counts on representative tables ===="
    kubectl -n "$ns" exec "$pg_pod" -- \
      psql -U postgres -d trakrf -c \
        "SELECT 'organizations' AS table_name, count(*) FROM trakrf.organizations
         UNION ALL
         SELECT 'users', count(*) FROM trakrf.users;"

    # Emptiness gate: judged on the trakrf schema AS A WHOLE (total tables +
    # total estimated rows), never on any single table, so a legitimately
    # empty table today (prod's tag_scans is 0 rows with 0 chunks — a known
    # ingestion gap, TRA-900) can never trip a false alarm on its own. A
    # restore that comes back with zero tables, or with every table's row
    # estimate at zero, did not bring back real data and must fail loudly
    # rather than report a hollow success.
    #
    # HYPERTABLES are aggregated separately, and that is the whole point of
    # TRA-1059. trakrf.asset_scans and trakrf.tag_scans are TimescaleDB
    # hypertables whose rows live in chunk relations under
    # _timescaledb_internal, so the hypertable PARENT's reltuples is always
    # -1/0. Summing only relkind='r' relations in the trakrf schema scored
    # preview at ~242k estimated rows when the database actually held ~16.8M —
    # about 1.4% of the truth — so a PITR that recovered zero chunks would
    # still have passed. That is the same false-green class this gate exists to
    # prevent, one layer deeper, hiding the product's core time-series data.
    #
    # approximate_row_count() is the right instrument here for the same reason
    # reltuples is: it is derived purely from catalog data (the chunks'
    # reltuples, plus _timescaledb_catalog.compression_chunk_size's
    # numrows_pre_compression for compressed chunks — every one of those
    # relations is permanent and WAL-logged, verified on the live clusters), so
    # it survives a physical restore exactly as reltuples does. It also never
    # touches the heap, so it stays cheap on a 16.8M-row hypertable, unlike a
    # count(*) — the opposite trade-off from the logical sibling recipe, which
    # has a running stats collector and can afford exact counts.
    #
    # Hypertables are DISCOVERED from timescaledb_information.hypertables and
    # never hardcoded, so this survives any future migration that adds or
    # removes one, and works unchanged on prod's 15-table schema and preview's
    # 28-table schema. The timescaledb extension is a hard dependency of the
    # trakrf schema either way (it is loaded into template1 on this image), and
    # if it ever went missing this query would fail to parse and report
    # INCONCLUSIVE — a loud, safe answer, never a false PASS.
    #
    # "The check could not RUN" and "the restore is genuinely EMPTY" are two
    # different findings and must never be reported as the same thing. The
    # old `read -r a b <<< "$(...)"` shape conflated them: `set -e` does not
    # fire on a command substitution feeding a here-string, and `read`
    # against a here-string succeeds even when the string is empty — so one
    # transient connection drop or statement timeout produced empty stdout,
    # `${var:-0}` defaulted both fields to 0, and a perfectly healthy restore
    # was announced to the operator as EMPTY. During a recovery incident that
    # is the most expensive possible wrong answer. Capture first, check the
    # exit status, validate the shape, and only then judge emptiness.
    if ! gate_out=$(kubectl -n "$ns" exec "$pg_pod" -- \
      psql -U postgres -d trakrf -t -A -F' ' -c \
        "WITH ht AS (
             SELECT format('%I.%I', hypertable_schema, hypertable_name)::regclass AS rel
               FROM timescaledb_information.hypertables
              WHERE hypertable_schema = 'trakrf'
         ), ht_rows AS (
             SELECT count(*) AS n_tables,
                    coalesce(sum(GREATEST(approximate_row_count(rel), 0)), 0) AS n_rows
               FROM ht
         ), plain AS (
             SELECT count(*) AS n_tables,
                    coalesce(sum(GREATEST(c.reltuples::bigint, 0)), 0) AS n_rows
               FROM pg_class c
               JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = 'trakrf' AND c.relkind = 'r'
                AND c.oid NOT IN (SELECT rel::oid FROM ht)
         )
         SELECT plain.n_tables, plain.n_rows, ht_rows.n_tables, ht_rows.n_rows
           FROM plain, ht_rows;"); then
      echo >&2
      echo "ERROR: INCONCLUSIVE — the emptiness sanity-check query could not be RUN." >&2
      echo "The restore itself may be perfectly fine; this failure is about the check," >&2
      echo "not about the data. Do NOT read this as an empty restore." >&2
      echo "Re-run it by hand against the scratch cluster before concluding anything:" >&2
      echo "  kubectl -n ${ns} exec ${pg_pod} -- psql -U postgres -d trakrf -c \"\\dt trakrf.*\"" >&2
      exit 1
    fi

    # A zero exit with empty or unparseable output is likewise "could not
    # determine", not "empty": both fields must be present and numeric before
    # the emptiness verdict below is allowed to mean anything.
    read -r plain_tables plain_rows ht_tables ht_rows <<< "$gate_out"
    if ! [[ "$plain_tables" =~ ^[0-9]+$ ]] || ! [[ "$plain_rows" =~ ^[0-9]+$ ]] \
       || ! [[ "$ht_tables" =~ ^[0-9]+$ ]] || ! [[ "$ht_rows" =~ ^[0-9]+$ ]]; then
      echo >&2
      echo "ERROR: INCONCLUSIVE — the emptiness sanity-check query returned no usable output." >&2
      echo "It exited 0 but did not produce the expected" >&2
      echo "'<plain_tables> <plain_est_rows> <hypertables> <hypertable_est_rows>' quad, so" >&2
      echo "the check could not be evaluated. This is NOT evidence of an empty restore." >&2
      echo "Raw output was: [${gate_out}]" >&2
      exit 1
    fi

    # Totals decide the verdict; the split is what the operator needs to see.
    # A hypertable estimate of 0 while the plain tables are populated is the
    # exact shape of "the recovery lost every chunk", so it must never hide
    # inside a single aggregate number again.
    restored_table_count=$(( plain_tables + ht_tables ))
    restored_reltuples_sum=$(( plain_rows + ht_rows ))

    echo
    echo "==== emptiness check: ${restored_table_count} tables in trakrf schema (${plain_tables} plain + ${ht_tables} hypertable) ===="
    echo "====   ~${restored_reltuples_sum} total estimated rows: ~${plain_rows} in plain tables + ~${ht_rows} in hypertable chunks ===="
    if [ "$restored_table_count" -eq 0 ] || [ "$restored_reltuples_sum" -eq 0 ]; then
      echo "FAIL: the check RAN and the restored trakrf schema is EMPTY (0 tables, or 0 total estimated rows across all tables and hypertables)." >&2
      echo "This is not a passing PITR proof — it did not verify real data landed." >&2
      exit 1
    fi
    echo "PASS: trakrf schema restored with ${restored_table_count} tables and real (non-zero) data,"
    echo "      including ~${ht_rows} time-series rows across ${ht_tables} hypertable(s)."

    echo
    echo "Tearing down scratch cluster..."
    kubectl -n "$ns" delete cluster "$scratch" --wait=true
    scratch_applied=0
    echo "PITR restore proof complete for {{ ENV }} (source ${src_cluster})."

# Interactive psql on the CNPG primary. Superuser via in-pod peer auth.
#   just psql preview
#   just psql prod
psql ENV:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/ops-lib.sh
    require_env "{{ ENV }}"
    ns="trakrf-{{ ENV }}"
    pod=$(cnpg_primary_pod "$ns")
    echo "→ $ns/$pod (database: trakrf)"
    kubectl -n "$ns" exec -it "$pod" -c postgres -- psql -U postgres -d trakrf

# CNPG cluster health plus its instance pods.
#   just db-status prod
db-status ENV:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/ops-lib.sh
    require_env "{{ ENV }}"
    ns="trakrf-{{ ENV }}"
    kubectl -n "$ns" get cluster "trakrf-db-{{ ENV }}"
    echo
    kubectl -n "$ns" get pods -l "cnpg.io/cluster=trakrf-db-{{ ENV }}" -o wide

# All pods in an environment, wide.
#   just pods prod
pods ENV:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/ops-lib.sh
    require_env "{{ ENV }}"
    kubectl -n "trakrf-{{ ENV }}" get pods -o wide

# Follow backend logs. SINCE defaults to 10m.
#   just logs prod
#   just logs prod 1h
logs ENV SINCE="10m":
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/ops-lib.sh
    require_env "{{ ENV }}"
    SINCE="{{ SINCE }}"
    kubectl -n "trakrf-{{ ENV }}" logs -l app.kubernetes.io/name=trakrf-backend \
        --since="$SINCE" --tail=200 -f

# Backend rollout status plus recent revision history.
#   just rollout prod
rollout ENV:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/ops-lib.sh
    require_env "{{ ENV }}"
    ns="trakrf-{{ ENV }}"
    kubectl -n "$ns" rollout status deploy/trakrf-backend --timeout=30s || true
    echo
    kubectl -n "$ns" get deploy trakrf-backend \
        -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,IMAGE:'.spec.template.spec.containers[0].image'

# Restart the backend deployment. Prompts before touching prod.
#   just backend-restart preview
#   YES=1 just backend-restart prod
backend-restart ENV:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/ops-lib.sh
    require_env "{{ ENV }}"
    confirm_prod "{{ ENV }}" "rollout restart deploy/trakrf-backend"
    ns="trakrf-{{ ENV }}"
    kubectl -n "$ns" rollout restart deploy/trakrf-backend
    kubectl -n "$ns" rollout status deploy/trakrf-backend --timeout=120s || true

# Override the backend log level on the live deployment.
#
# EPHEMERAL: LOG_LEVEL is rendered into a ConfigMap by the trakrf-backend
# chart from `config.runtimeLogLevel` and is managed by ArgoCD, so the next
# sync reverts this. For a durable change, edit the per-env inlineValues in
# argocd/root/templates/ and re-run scripts/apply-root-app.sh gke.
#
#   just set-log-level preview debug
set-log-level ENV LEVEL:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/ops-lib.sh
    require_env "{{ ENV }}"
    case "{{ LEVEL }}" in
        debug|info|warn|error) ;;
        *) echo "ERROR: LEVEL must be debug|info|warn|error, got '{{ LEVEL }}'" >&2; exit 1 ;;
    esac
    confirm_prod "{{ ENV }}" "set LOG_LEVEL={{ LEVEL }} on deploy/trakrf-backend"
    ns="trakrf-{{ ENV }}"
    kubectl -n "$ns" set env deploy/trakrf-backend LOG_LEVEL={{ LEVEL }}
    kubectl -n "$ns" rollout status deploy/trakrf-backend --timeout=120s || true
    echo
    echo "⚠️  EPHEMERAL — ArgoCD will revert this on the next sync of trakrf-backend-{{ ENV }}."
    echo "   Durable path: argocd/root/templates/ inlineValues + scripts/apply-root-app.sh gke"

# Follow broker logs.
#   just mqtt-logs prod
mqtt-logs ENV:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/ops-lib.sh
    require_env "{{ ENV }}"
    kubectl -n "trakrf-{{ ENV }}" logs -l app.kubernetes.io/name=trakrf-mosquitto \
        -c mosquitto --tail=100 -f

# Subscribe to a topic from inside the broker pod (loopback listener, no TLS
# setup needed). Credentials are read live from the trakrf-mosquitto-auth
# Secret, not from the environment. Ctrl-C to stop.
#   just mqtt-sub preview '#'
#   just mqtt-sub prod 'trakrf.id/+/tag_scan'
mqtt-sub ENV TOPIC:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/ops-lib.sh
    require_env "{{ ENV }}"
    ns="trakrf-{{ ENV }}"
    topic='{{ TOPIC }}'
    user=$(kubectl -n "$ns" get secret trakrf-mosquitto-auth -o jsonpath='{.data.username}' | base64 -d)
    pass=$(kubectl -n "$ns" get secret trakrf-mosquitto-auth -o jsonpath='{.data.password}' | base64 -d)
    echo "→ $ns broker, user $user, topic $topic (Ctrl-C to stop)"
    kubectl -n "$ns" exec -i deploy/trakrf-mosquitto -c mosquitto -- \
        mosquitto_sub -h 127.0.0.1 -p 1883 -u "$user" -P "$pass" -t "$topic" -v

# ============================================================================
# Worktree Support
# ============================================================================

# Symlink .env.local from the main worktree so direnv + env-dependent recipes
# (tofu, *-secrets, apply-root-app) work from a worktree. The repo's .env.local
# lives only in the main checkout (gitignored, not copied into worktrees), so a
# bare worktree gets no env and tofu/R2 + mosquitto-secrets fail or run with
# stale inherited values. Symlink (not copy) so secret rotations in main
# propagate automatically. Safe to run repeatedly; no-op in the main worktree.
worktree-bootstrap:
    #!/usr/bin/env bash
    set -euo pipefail
    main_dir=$(git worktree list --porcelain | awk '/^worktree /{p=$2} /^branch refs\/heads\/main$/{print p; exit}')
    if [ -z "${main_dir:-}" ]; then
        echo "❌ Cannot locate main worktree (no branch refs/heads/main in git worktree list)" >&2
        exit 1
    fi
    here=$(git rev-parse --show-toplevel)
    if [ "$main_dir" = "$here" ]; then
        echo "ℹ️  Already in main worktree — nothing to bootstrap"
        exit 0
    fi
    if [ ! -f "$main_dir/.env.local" ]; then
        echo "❌ $main_dir/.env.local not found — nothing to link" >&2
        exit 1
    fi
    ln -sf "$main_dir/.env.local" "$here/.env.local"
    echo "✅ Linked .env.local from $main_dir"
    echo "   Run \`direnv allow\` (or re-enter the dir) to load it."
