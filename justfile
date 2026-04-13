export TF_VAR_account_id := env_var("CLOUDFLARE_ACCOUNT_ID")
export TF_VAR_bucket_name := env_var("CLOUDFLARE_TF_STATE_BUCKET")
export TF_VAR_domain_name := env_var("DOMAIN_NAME")

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
    @printf 'endpoints = { s3 = "%s" }\n' "{{r2_endpoint}}" > {{dir}}/backend.conf

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

# Plan and apply AWS infrastructure (Route53, EKS)
aws: (_backend-conf "terraform/aws")
    @echo "Planning AWS infrastructure..."
    @tofu -chdir=terraform/aws init -backend-config=backend.conf
    @tofu -chdir=terraform/aws plan -out=tfplan
    @tofu -chdir=terraform/aws apply tfplan

# List objects in the R2 terraform state bucket
s3-ls:
    @aws s3 ls s3://tf-state --endpoint-url "{{r2_endpoint}}" --profile cloudflare-r2

# Install ArgoCD via Helm and apply root app-of-apps
argocd-bootstrap:
    @grep -rq 'ARGOCD_IRSA_ROLE_ARN' argocd/ && { echo "ERROR: Replace ARGOCD_IRSA_ROLE_ARN placeholder in argocd/ before bootstrapping."; echo "Get the ARN with: tofu -chdir=terraform/aws output -json irsa_role_arns | jq -r .argocd"; exit 1; } || true
    @echo "Adding ArgoCD Helm repo..."
    @helm repo add argo https://argoproj.github.io/argo-helm
    @helm repo update argo
    @echo "Installing ArgoCD into argocd namespace..."
    @helm install argocd argo/argo-cd --namespace argocd --create-namespace -f argocd/bootstrap/values.yaml
    @echo "Waiting for ArgoCD server to be ready..."
    @kubectl rollout status deployment/argocd-server -n argocd --timeout=120s
    @echo "Applying root app-of-apps..."
    @kubectl apply -f argocd/projects/trakrf.yaml
    @kubectl apply -f argocd/root.yaml
    @echo "ArgoCD bootstrap complete. Run 'just argocd-password' for the admin password."

# Fetch ArgoCD initial admin password
argocd-password:
    @kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d && echo

# Port-forward ArgoCD UI to :8080 (all interfaces)
argocd-ui:
    @echo "ArgoCD UI at https://<host-ip>:8080 (admin / <just argocd-password>)"
    @kubectl port-forward svc/argocd-server -n argocd 8080:443 --address 0.0.0.0

# Sync platform backend migrations into the trakrf-backend chart (TRA-361 temporary path).
# Remove once migrate.image points at the backend image published by TRA-363.
sync-migrations:
    @echo "Syncing migrations from ../platform/backend/migrations/ → helm/trakrf-backend/migrations/"
    @mkdir -p helm/trakrf-backend/migrations
    @rsync -av --delete --include='*.up.sql' --exclude='*' ../platform/backend/migrations/ helm/trakrf-backend/migrations/
    @ls helm/trakrf-backend/migrations/ | wc -l | xargs -I{} echo "Synced {} migration files"

# Install kube-prometheus-stack into monitoring namespace
monitoring-bootstrap:
    @echo "Adding prometheus-community Helm repo..."
    @helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    @helm repo update prometheus-community
    @echo "Installing kube-prometheus-stack into monitoring namespace..."
    @helm upgrade --install kube-prometheus-stack \
      prometheus-community/kube-prometheus-stack \
      --version 83.4.1 \
      --namespace monitoring --create-namespace \
      -f helm/monitoring/values.yaml
    @echo "Waiting for Grafana to be ready..."
    @kubectl rollout status deployment/kube-prometheus-stack-grafana -n monitoring --timeout=300s
    @echo "Building dashboards ConfigMap from helm/monitoring/dashboards/..."
    @kubectl create configmap kube-prometheus-stack-dashboards \
      --namespace monitoring \
      --from-file=helm/monitoring/dashboards/ \
      --dry-run=client -o yaml \
      | kubectl label --local -f - grafana_dashboard=1 -o yaml --dry-run=client \
      | kubectl apply --server-side --force-conflicts -f -
    @echo "Applying out-of-chart manifests (CNPG ServiceMonitor, dashboards)..."
    @kubectl apply --server-side --force-conflicts -n monitoring -f helm/monitoring/manifests/

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
