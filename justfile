export TF_VAR_account_id := env_var("CLOUDFLARE_ACCOUNT_ID")
export TF_VAR_bucket_name := env_var("CLOUDFLARE_TF_STATE_BUCKET")
export TF_VAR_domain_name := env_var("DOMAIN_NAME")
export AWS_DEFAULT_REGION := "auto"

default: list

list:
  @just --list

env:
    @env

bootstrap:
    @echo "Bootstrapping cloudflare resources on ${DOMAIN_NAME}"
    @CLOUDFLARE_API_TOKEN=$CLOUDFLARE_BOOTSTRAP_API_TOKEN tofu -chdir=bootstrap init
    @CLOUDFLARE_API_TOKEN=$CLOUDFLARE_BOOTSTRAP_API_TOKEN tofu -chdir=bootstrap plan -out=tfplan
    @CLOUDFLARE_API_TOKEN=$CLOUDFLARE_BOOTSTRAP_API_TOKEN tofu -chdir=bootstrap apply tfplan | grep -v '<sensitive>'
    @CLOUDFLARE_API_TOKEN=$CLOUDFLARE_BOOTSTRAP_API_TOKEN tofu -chdir=bootstrap output -show-sensitive | grep -E '(secret|infra)'

domains:
    @echo "Planning cloudflare resources on ${DOMAIN_NAME}"
    @tofu -chdir=domains init
    @tofu -chdir=domains plan -out=tfplan
    @tofu -chdir=domains apply tfplan
#    @tofu -chdir=domains apply tfplan | grep -v '<sensitive>'
#    @tofu -chdir=domains output -show-sensitive | grep -E '(secret|infra)'

s3-ls:
    @aws s3 ls s3://tf-state --endpoint-url "https://$CLOUDFLARE_ACCOUNT_ID.r2.cloudflarestorage.com"
