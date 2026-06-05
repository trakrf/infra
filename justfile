export TF_VAR_account_id := env_var("CLOUDFLARE_ACCOUNT_ID")
export TF_VAR_bucket_name := env_var("CLOUDFLARE_TF_STATE_BUCKET")
export TF_VAR_domain_name := env_var("DOMAIN_NAME")
export TF_VAR_eks_nlb_hostname := env_var("EKS_NLB_HOSTNAME")

r2_endpoint := "https://" + env_var("CLOUDFLARE_ACCOUNT_ID") + ".r2.cloudflarestorage.com"

default: list

# List available recipes
list:
  @just --list

# Print environment variables
env:
    @env

# Generate backend.conf for S3/R2 endpoint (gitignored, never committed)
_backend-conf dir:
    @printf 'endpoints = { s3 = "%s" }\nprofile = "cloudflare-r2"\n' "{{r2_endpoint}}" > {{dir}}/backend.conf

# One-time setup: create R2 state bucket and API tokens
bootstrap:
    @echo "Bootstrapping cloudflare resources on ${DOMAIN_NAME}"
    @CLOUDFLARE_API_TOKEN=$CLOUDFLARE_BOOTSTRAP_API_TOKEN tofu -chdir=terraform/bootstrap init
    @CLOUDFLARE_API_TOKEN=$CLOUDFLARE_BOOTSTRAP_API_TOKEN tofu -chdir=terraform/bootstrap plan -out=tfplan
    @CLOUDFLARE_API_TOKEN=$CLOUDFLARE_BOOTSTRAP_API_TOKEN tofu -chdir=terraform/bootstrap apply tfplan | grep -v '<sensitive>'
    @CLOUDFLARE_API_TOKEN=$CLOUDFLARE_BOOTSTRAP_API_TOKEN tofu -chdir=terraform/bootstrap output -show-sensitive | grep -E '(secret|infra)'

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
    @aws s3 ls s3://tf-state --endpoint-url "{{r2_endpoint}}" --profile cloudflare-r2

# Fetch AKS kubeconfig via az CLI, convert to azurecli auth (needs kubelogin)
aks-creds:
    @RG=$(tofu -chdir=terraform/azure output -raw resource_group_name) && \
     CLUSTER=$(tofu -chdir=terraform/azure output -raw cluster_name) && \
     az aks get-credentials --resource-group $RG --name $CLUSTER --overwrite-existing && \
     kubelogin convert-kubeconfig -l azurecli && \
     kubectl config use-context $CLUSTER

# Fetch GKE kubeconfig via gcloud. Requires gke-gcloud-auth-plugin.
gke-creds:
    @PROJECT=$(tofu -chdir=terraform/gcp output -raw project_id) && \
     CLUSTER=$(tofu -chdir=terraform/gcp output -raw cluster_name) && \
     ZONE=$(tofu -chdir=terraform/gcp output -raw zone) && \
     gcloud container clusters get-credentials $CLUSTER --zone $ZONE --project $PROJECT && \
     kubectl config use-context gke_${PROJECT}_${ZONE}_${CLUSTER}

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
#   MOSQUITTO_FRONTEND_USER      (optional) read-only frontend user; default
#                        frontend-readonly. Subscribe-only on trakrf.id/+/reads
#                        (acl in the trakrf-mosquitto chart). TRA-902 reader feed.
#   MOSQUITTO_FRONTEND_PASSWORD  (optional) if set, a 2nd user is added to the
#                        password_file + literal creds to the Secret
#                        (frontend_username/frontend_password) for the public
#                        VITE bundle. Unset → skipped.
#
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
    @# mosquitto_passwd binary. Builds the hashed password_file (the shared user,
    @# plus an optional read-only frontend user when MOSQUITTO_FRONTEND_PASSWORD
    @# is set), then folds it into a Secret alongside the literal creds (the
    @# frontend_* keys feed the public VITE bundle for the TRA-902 reader feed).
    @FRONTEND_USER="${MOSQUITTO_FRONTEND_USER:-frontend-readonly}"; \
     PASSWD_FILE=$(docker run --rm eclipse-mosquitto:2.0.21 sh -c \
      "mosquitto_passwd -b -c /tmp/passwd '${MOSQUITTO_USER}' '${MOSQUITTO_PASSWORD}' >/dev/null; \
       if [ -n '${MOSQUITTO_FRONTEND_PASSWORD:-}' ]; then mosquitto_passwd -b /tmp/passwd '${FRONTEND_USER}' '${MOSQUITTO_FRONTEND_PASSWORD}' >/dev/null; fi; \
       cat /tmp/passwd") && \
     kubectl create secret generic trakrf-mosquitto-auth -n trakrf-system \
       --from-literal=passwd="$PASSWD_FILE" \
       --from-literal=username="${MOSQUITTO_USER}" \
       --from-literal=password="${MOSQUITTO_PASSWORD}" \
       --from-literal=frontend_username="${FRONTEND_USER}" \
       --from-literal=frontend_password="${MOSQUITTO_FRONTEND_PASSWORD:-}" \
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
# into a scratch database on the live CNPG cluster, run a sanity query,
# drop the scratch database. Requires:
#   - `gcloud auth application-default login` (for `gcloud storage`)
#   - kubectl context pointed at the GKE cluster
#
# Usage:
#   just db-restore-test            # defaults to preview
#   just db-restore-test prod
db-restore-test ENV="preview":
    #!/usr/bin/env bash
    set -euo pipefail
    bucket=$(tofu -chdir=terraform/gcp output -raw cnpg_backup_bucket)
    echo "Looking for latest dump in gs://${bucket}/{{ ENV }}/..."
    latest=$(gcloud storage ls "gs://${bucket}/{{ ENV }}/**/*.pgdump" | sort | tail -1)
    test -n "$latest" || { echo "no dumps found in gs://${bucket}/{{ ENV }}/"; exit 1; }
    echo "Latest dump: $latest"

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    gcloud storage cp "$latest" "$tmp/dump.pgdump"
    ls -la "$tmp/dump.pgdump"

    # `kubectl exec ... psql -U postgres` on the CNPG primary uses peer
    # auth via the unix socket — no password needed.
    pg_pod=$(kubectl -n trakrf-system get pod \
      -l cnpg.io/cluster=trakrf-db,role=primary \
      -o jsonpath='{.items[0].metadata.name}')
    test -n "$pg_pod" || { echo "no CNPG primary pod found"; exit 1; }
    scratch="trakrf_restore_test_$(date -u +%s)"

    echo "Creating scratch DB ${scratch} on ${pg_pod}..."
    # Create the scratch DB with the timescaledb extension pre-installed,
    # then bracket pg_restore with timescaledb_pre_restore / _post_restore.
    # Without that bracketing, pg_restore emits "ONLY option not supported
    # on hypertable operations" while replaying foreign-key constraints
    # and exits non-zero — the standard Timescale logical-restore pattern.
    # See https://docs.timescale.com/self-hosted/latest/backup-and-restore/logical-backup/
    kubectl -n trakrf-system exec "${pg_pod}" -- \
      psql -U postgres -v ON_ERROR_STOP=1 \
        -c "CREATE DATABASE \"${scratch}\""
    kubectl -n trakrf-system exec "${pg_pod}" -- \
      psql -U postgres -d "${scratch}" -v ON_ERROR_STOP=1 \
        -c "CREATE EXTENSION IF NOT EXISTS timescaledb" \
        -c "SELECT timescaledb_pre_restore()"

    echo "Restoring dump into ${scratch}..."
    kubectl -n trakrf-system exec -i "${pg_pod}" -- \
      pg_restore --no-owner --no-privileges -U postgres -d "${scratch}" \
      < "$tmp/dump.pgdump"

    echo "Running timescaledb_post_restore()..."
    kubectl -n trakrf-system exec "${pg_pod}" -- \
      psql -U postgres -d "${scratch}" -v ON_ERROR_STOP=1 \
        -c "SELECT timescaledb_post_restore()"

    echo "Sanity check — schema + table row counts:"
    kubectl -n trakrf-system exec "${pg_pod}" -- \
      psql -U postgres -d "${scratch}" -v ON_ERROR_STOP=1 \
        -c "\dn" \
        -c "SELECT schemaname, relname, n_live_tup
            FROM pg_stat_user_tables
            WHERE schemaname = 'trakrf'
            ORDER BY relname;"

    echo "Dropping scratch DB ${scratch}..."
    kubectl -n trakrf-system exec "${pg_pod}" -- \
      psql -U postgres -c "DROP DATABASE \"${scratch}\""

    echo "Restore proof complete for ENV={{ ENV }}."

# Manually trigger an ad-hoc CNPG Backup CR against the trakrf-db
# cluster. Useful for first-install verification (don't wait for the
# scheduled run) or for taking a guaranteed-fresh base backup before a
# risky operation.
#
# Usage: just db-pitr-trigger-base
db-pitr-trigger-base:
    #!/usr/bin/env bash
    set -euo pipefail
    # kubectl apply requires a fixed name; embed a timestamp for uniqueness.
    name="trakrf-db-manual-$(date -u +%Y%m%d%H%M%S)"
    kubectl -n trakrf-system apply -f - <<EOF
    apiVersion: postgresql.cnpg.io/v1
    kind: Backup
    metadata:
      name: ${name}
      namespace: trakrf-system
    spec:
      cluster:
        name: trakrf-db
      method: barmanObjectStore
    EOF
    echo "Backup CR ${name} submitted. Watch with: kubectl -n trakrf-system get backup -w"

# Proves CNPG PITR by spinning up a scratch Cluster that recovers from
# the barman object store, optionally to a specific point in time. The
# scratch cluster always uses the fixed name `trakrf-restore-test` so
# the static WI binding in terraform/gcp/cnpg_backups.tf fits.
#
# Idempotent: pre-deletes any leftover scratch cluster before applying.
#
# Usage:
#   just db-restore-pitr-test               # recover to latest available
#   just db-restore-pitr-test "2026-05-27T10:30:00Z"
db-restore-pitr-test TARGET_TIME="":
    #!/usr/bin/env bash
    set -euo pipefail
    bucket=$(tofu -chdir=terraform/gcp output -raw cnpg_backup_bucket)
    gsa=$(tofu -chdir=terraform/gcp output -raw cnpg_backups_service_account_email)
    scratch=trakrf-restore-test
    ns=trakrf-system

    echo "Pre-cleanup: deleting any leftover ${scratch} cluster..."
    kubectl -n "$ns" delete cluster "$scratch" --ignore-not-found --wait=true

    target_block=""
    if [[ -n "{{ TARGET_TIME }}" ]]; then
      target_block=$'\n      recoveryTarget:\n        targetTime: "{{ TARGET_TIME }}"'
    fi

    echo "Applying scratch Cluster ${scratch} pointing at gs://${bucket}/trakrf-db ..."
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
        size: 5Gi
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
            serverName: trakrf-db
            googleCredentials:
              gkeEnvironment: true
            wal:
              compression: gzip
    EOF

    echo "Waiting up to 10 min for scratch cluster to become Ready..."
    kubectl -n "$ns" wait --for=condition=Ready cluster/${scratch} --timeout=10m

    pg_pod=$(kubectl -n "$ns" get pod -l cnpg.io/cluster=${scratch},role=primary \
              -o jsonpath='{.items[0].metadata.name}')
    test -n "$pg_pod" || { echo "no scratch primary pod found"; exit 1; }

    echo
    echo "==== databases in recovered cluster ===="
    kubectl -n "$ns" exec "$pg_pod" -- psql -U postgres -c "\l"

    for db in trakrf_preview trakrf_prod; do
      echo
      echo "==== ${db}: trakrf schema rowcounts ===="
      kubectl -n "$ns" exec "$pg_pod" -- \
        psql -U postgres -d "$db" -c "\dn" \
        -c "SELECT schemaname, relname, n_live_tup
            FROM pg_stat_user_tables
            WHERE schemaname='trakrf'
            ORDER BY relname;" || echo "(${db} not present at target time)"
    done

    echo
    echo "Tearing down scratch cluster..."
    kubectl -n "$ns" delete cluster "$scratch" --wait=true
    echo "PITR restore proof complete."
