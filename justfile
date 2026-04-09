export TF_VAR_account_id := env_var("CLOUDFLARE_ACCOUNT_ID")
export TF_VAR_bucket_name := env_var("CLOUDFLARE_TF_STATE_BUCKET")
export TF_VAR_domain_name := env_var("DOMAIN_NAME")
export TF_VAR_aws_access_key_id := env_var("AWS_ACCESS_KEY_ID")
export TF_VAR_aws_secret_access_key := env_var("AWS_SECRET_ACCESS_KEY")
export AWS_DEFAULT_REGION := "auto"

r2_endpoint := "https://" + env_var("CLOUDFLARE_ACCOUNT_ID") + ".r2.cloudflarestorage.com"

default: list

list:
  @just --list

env:
    @env

# Generate backend.conf for S3/R2 endpoint (gitignored, never committed)
_backend-conf dir:
    @printf 'endpoints = { s3 = "%s" }\n' "{{r2_endpoint}}" > {{dir}}/backend.conf

bootstrap:
    @echo "Bootstrapping cloudflare resources on ${DOMAIN_NAME}"
    @CLOUDFLARE_API_TOKEN=$CLOUDFLARE_BOOTSTRAP_API_TOKEN tofu -chdir=bootstrap init
    @CLOUDFLARE_API_TOKEN=$CLOUDFLARE_BOOTSTRAP_API_TOKEN tofu -chdir=bootstrap plan -out=tfplan
    @CLOUDFLARE_API_TOKEN=$CLOUDFLARE_BOOTSTRAP_API_TOKEN tofu -chdir=bootstrap apply tfplan | grep -v '<sensitive>'
    @CLOUDFLARE_API_TOKEN=$CLOUDFLARE_BOOTSTRAP_API_TOKEN tofu -chdir=bootstrap output -show-sensitive | grep -E '(secret|infra)'

domains: (_backend-conf "domains")
    @echo "Planning cloudflare resources on ${DOMAIN_NAME}"
    @tofu -chdir=domains init -backend-config=backend.conf
    @tofu -chdir=domains plan -out=tfplan
    @tofu -chdir=domains apply tfplan

aws: (_backend-conf "aws")
    @echo "Planning AWS infrastructure..."
    @tofu -chdir=aws init -backend-config=backend.conf
    @tofu -chdir=aws plan -out=tfplan
    @tofu -chdir=aws apply tfplan

s3-ls:
    @aws s3 ls s3://tf-state --endpoint-url "{{r2_endpoint}}"
