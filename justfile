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
    latest=$(gcloud storage ls "gs://${bucket}/${cluster}/dump/**/*.pgdump" | sort | tail -1)
    test -n "$latest" || { echo "no dumps found in gs://${bucket}/${cluster}/dump/"; exit 1; }
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
    kubectl -n "$ns" exec "${pg_pod}" -- \
      psql -U postgres -d "${scratch}" -v ON_ERROR_STOP=1 \
        -c "\dn" \
        -c "SELECT schemaname, relname, n_live_tup
            FROM pg_stat_user_tables
            WHERE schemaname = 'trakrf'
            ORDER BY relname;"

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
# Usage:
#   just db-restore-pitr-test preview
#   just db-restore-pitr-test prod
#   just db-restore-pitr-test prod "2026-05-27T10:30:00Z"
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
    echo "Recovering ${src_cluster} from gs://${bucket}/${src_cluster} as ${gsa} (storage ${storage_size})"

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
      imageName: ghcr.io/clevyr/cloudnativepg-timescale:17.2-ts2.18
      storage:
        size: ${storage_size}
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

    # 20m, not 10m: a real restore replays a full base backup plus WAL, and
    # that alone has measured ~18 minutes on this cluster once storage is
    # sized correctly — a multi-minute wait here is normal and healthy, not
    # a hang.
    echo "Waiting up to 20 min for scratch cluster to become Ready. Restoring a" \
         "multi-GB base backup and replaying WAL can genuinely take most of" \
         "that — a slow-but-progressing restore is expected, not a hang."
    if ! kubectl -n "$ns" wait --for=condition=Ready cluster/${scratch} --timeout=20m; then
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
    echo
    echo "==== trakrf: schema + catalog row-count overview (pg_class.reltuples) ===="
    kubectl -n "$ns" exec "$pg_pod" -- \
      psql -U postgres -d trakrf -c "\dn" \
      -c "SELECT n.nspname AS schemaname, c.relname,
                 CASE WHEN c.reltuples < 0 THEN NULL ELSE c.reltuples::bigint END AS est_rows
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = 'trakrf' AND c.relkind = 'r'
          ORDER BY c.relname;"

    echo
    echo "==== trakrf: exact row counts on representative tables ===="
    kubectl -n "$ns" exec "$pg_pod" -- \
      psql -U postgres -d trakrf -c \
        "SELECT 'organizations' AS table_name, count(*) FROM trakrf.organizations
         UNION ALL
         SELECT 'users', count(*) FROM trakrf.users;"

    # Emptiness gate: judged on the trakrf schema AS A WHOLE (total tables +
    # total estimated rows), never on any single table, so a legitimately
    # empty table today (tag_scans/asset_scans — a known ingestion gap,
    # TRA-900) can never trip a false alarm on its own. A restore that comes
    # back with zero tables, or with every table's row estimate at zero,
    # did not bring back real data and must fail loudly rather than report
    # a hollow success.
    read -r restored_table_count restored_reltuples_sum <<< "$(kubectl -n "$ns" exec "$pg_pod" -- \
      psql -U postgres -d trakrf -t -A -F' ' -c \
        "SELECT count(*), coalesce(sum(GREATEST(c.reltuples::bigint, 0)), 0)
         FROM pg_class c
         JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'trakrf' AND c.relkind = 'r';")"

    echo
    echo "==== emptiness check: ${restored_table_count:-0} tables, ~${restored_reltuples_sum:-0} total estimated rows in trakrf schema ===="
    if [ "${restored_table_count:-0}" -eq 0 ] || [ "${restored_reltuples_sum:-0}" -eq 0 ]; then
      echo "FAIL: restored trakrf schema looks EMPTY (0 tables, or 0 total estimated rows across all tables)." >&2
      echo "This is not a passing PITR proof — it did not verify real data landed." >&2
      exit 1
    fi
    echo "PASS: trakrf schema restored with ${restored_table_count} tables and real (non-zero) data."

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
