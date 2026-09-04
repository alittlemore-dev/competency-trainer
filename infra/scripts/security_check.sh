#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "${script_dir}/../.." && pwd)"
minio_check_image_tag=""
minio_check_temp_dir=""
nginx_check_temp_dir=""
nginx_check_image_tag=""
nginx_check_container_name=""
nginx_recovery_container_name=""
nginx_check_network_name=""
agent_api_probe_container_name=""
agent_api_check_image_tag=""
nginx_recreate_project_name=""
nginx_recreate_temp_dir=""

cleanup_security_check_images() {
    if [ -n "$nginx_recreate_project_name" ] \
        && [ -n "$nginx_recreate_temp_dir" ] \
        && [ -f "${nginx_recreate_temp_dir}/new-compose.yml" ]; then
        docker compose \
            -p "$nginx_recreate_project_name" \
            -f "${nginx_recreate_temp_dir}/new-compose.yml" \
            down -v --remove-orphans >/dev/null 2>&1 || true
    fi
    if [ -n "$minio_check_image_tag" ]; then
        docker image rm "$minio_check_image_tag" >/dev/null 2>&1 || true
    fi
    if [ -n "$minio_check_temp_dir" ]; then
        rm -rf "$minio_check_temp_dir"
    fi
    if [ -n "$nginx_check_container_name" ]; then
        docker rm -f "$nginx_check_container_name" >/dev/null 2>&1 || true
    fi
    if [ -n "$nginx_recovery_container_name" ]; then
        docker rm -f "$nginx_recovery_container_name" >/dev/null 2>&1 || true
    fi
    if [ -n "$agent_api_probe_container_name" ]; then
        docker rm -f "$agent_api_probe_container_name" >/dev/null 2>&1 || true
    fi
    if [ -n "$nginx_check_image_tag" ]; then
        docker image rm "$nginx_check_image_tag" >/dev/null 2>&1 || true
    fi
    if [ -n "$nginx_check_temp_dir" ]; then
        rm -rf "$nginx_check_temp_dir"
    fi
    if [ -n "$agent_api_check_image_tag" ]; then
        docker image rm "$agent_api_check_image_tag" >/dev/null 2>&1 || true
    fi
    if [ -n "$nginx_check_network_name" ]; then
        docker network rm "$nginx_check_network_name" >/dev/null 2>&1 || true
    fi
    if [ -n "$nginx_recreate_temp_dir" ]; then
        rm -rf "$nginx_recreate_temp_dir"
    fi
}

require_command() {
    local command_name="$1"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "${command_name} could not be found." >&2
        exit 2
    fi
}

require_file_contains() {
    local file_path="$1"
    local pattern="$2"
    local description="$3"

    if ! grep -Fq -- "$pattern" "$file_path"; then
        echo "Missing ${description} in ${file_path}: ${pattern}" >&2
        exit 1
    fi
}

require_file_not_contains() {
    local file_path="$1"
    local pattern="$2"
    local description="$3"

    if grep -Fq -- "$pattern" "$file_path"; then
        echo "Unexpected ${description} in ${file_path}: ${pattern}" >&2
        exit 1
    fi
}

require_file_pattern_before() {
    local file_path="$1"
    local first_pattern="$2"
    local second_pattern="$3"
    local description="$4"
    local first_line
    local second_line

    first_line="$(grep -n -F -m 1 -- "$first_pattern" "$file_path" | cut -d: -f1 || true)"
    second_line="$(grep -n -F -m 1 -- "$second_pattern" "$file_path" | cut -d: -f1 || true)"
    if [ -z "$first_line" ] || [ -z "$second_line" ] || [ "$first_line" -ge "$second_line" ]; then
        echo "Invalid ${description} in ${file_path}: ${first_pattern} must precede ${second_pattern}" >&2
        exit 1
    fi
}

require_compose_service_contains() {
    local compose_file="$1"
    local service_name="$2"
    local pattern="$3"
    local description="$4"

    if ! awk -v service_line="  ${service_name}:" -v pattern="$pattern" '
        $0 == service_line {
            in_service = 1
            next
        }
        in_service && $0 ~ /^  [A-Za-z0-9_-]+:$/ {
            exit
        }
        in_service && index($0, pattern) > 0 {
            found = 1
            exit
        }
        END {
            exit found ? 0 : 1
        }
    ' "$compose_file"; then
        echo "Missing ${description} for Compose service ${service_name}: ${pattern}" >&2
        exit 1
    fi
}

require_no_latest_image_tags() {
    local file_path
    local failed=0

    for file_path in "$@"; do
        if grep -En '(^|[[:space:]-])[[:alnum:]_./-]+:latest([[:space:]]|$)' "$file_path"; then
            echo "Unexpected Docker latest image tag in ${file_path}." >&2
            failed=1
        fi
    done

    if [ "$failed" -ne 0 ]; then
        exit 1
    fi
}

require_file_exists() {
    local file_path="$1"
    local description="$2"

    if [ ! -f "$file_path" ]; then
        echo "Missing ${description}: ${file_path}" >&2
        exit 1
    fi
}

require_frontend_location_has_no_proxy_headers() {
    local file_path="$1"

    if awk '
        $0 ~ /^[[:space:]]*location \/ \{/ {
            in_frontend_location = 1
            next
        }
        in_frontend_location && $0 ~ /^[[:space:]]*\}/ {
            in_frontend_location = 0
            next
        }
        in_frontend_location && $0 ~ /proxy_set_header/ {
            found = 1
        }
        END { exit found ? 0 : 1 }
    ' "$file_path"; then
        echo "Frontend location must inherit server-level proxy headers; move location-level proxy_set_header directives to the server block." >&2
        exit 1
    fi
}

require_file_not_exists() {
    local file_path="$1"
    local description="$2"

    if [ -f "$file_path" ]; then
        echo "Unexpected ${description}: ${file_path}" >&2
        exit 1
    fi
}

require_no_unapproved_network_literals() {
    local description="$1"
    local pattern="$2"
    shift 2

    local file_path
    local line
    local failed=0

    for file_path in "$@"; do
        while IFS= read -r line; do
            case "$line" in
                *"127.0.0.11"*) ;;
                *"127.0.0.1:8080/api/healthcheck/ready"*) ;;
                *"127.0.0.1:4000/healthz"*) ;;
                *"127.0.0.1:8080/nginx-healthz"*) ;;
                *"localhost:9000/minio/health/live"*) ;;
                *)
                    echo "Unexpected ${description} in ${line}" >&2
                    failed=1
                    ;;
            esac
        done < <(grep -En "$pattern" "$file_path" || true)
    done

    if [ "$failed" -ne 0 ]; then
        exit 1
    fi
}

require_no_inspect_visible_secret_environment() {
    local compose_file="$1"
    local secret_patterns=(
        "AGENT_ACCESS_ISSUING_PRIVATE_KEY:"
        "APP_SECRET_KEY:"
        "AUTH_PRIVATE_KEY:"
        "DB_PASSWORD:"
        "MINIO_ACCESS_KEY:"
        "MINIO_SECRET_KEY:"
        "MINIO_ROOT_PASSWORD:"
        "MINIO_ROOT_USER:"
        "OWNER_INIT_PASSWORD:"
        "POSTGRES_PASSWORD:"
        "SENTRY_DSN:"
    )
    local pattern

    require_file_not_contains "$compose_file" "env_file:" "inspect-visible environment file"

    for pattern in "${secret_patterns[@]}"; do
        require_file_not_contains "$compose_file" "$pattern" "inspect-visible secret environment"
    done
}

require_no_container_file_logs() {
    local file_path
    local line
    local failed=0

    for file_path in "$@"; do
        while IFS= read -r line; do
            case "$line" in
                *"access_log off;"*) ;;
                *"access_log /dev/stdout;"*) ;;
                *"access_log /dev/stdout "*) ;;
                *"error_log /dev/stderr"*) ;;
                *)
                    echo "Unexpected container file logging directive in ${line}" >&2
                    failed=1
                    ;;
            esac
        done < <(grep -En "(access_log|error_log|/var/log|FileHandler|RotatingFileHandler|--log-file|log_file)" "$file_path" || true)
    done

    if [ "$failed" -ne 0 ]; then
        exit 1
    fi
}

create_test_runtime_material() {
    local material_dir="$1"

    mkdir -p "$material_dir"
    bash "${repo_dir}/infra/scripts/agent_ca.sh" \
        init \
        "${material_dir}/offline" \
        "${material_dir}/issuing" >/dev/null
    echo "Generated test agent CA hierarchy."
    openssl genpkey \
        -algorithm EC \
        -pkeyopt ec_paramgen_curve:P-256 \
        -pkeyopt ec_param_enc:named_curve \
        -out "${material_dir}/auth-private.pem" 2>/dev/null
    echo "Generated test application signing key."
    openssl pkey \
        -in "${material_dir}/auth-private.pem" \
        -pubout \
        -out "${material_dir}/auth-public.pem" 2>/dev/null
}

export_test_runtime_environment() {
    local material_dir="$1"

    export IMAGE_TAG="security-check-sha"
    export OWNER_INIT_LOGIN="owner"
    export APP_CONTACT_REQUESTS_ENABLED="false"
    export APP_DEBUG="false"
    export APP_DOMAIN="example.test"
    export APP_URL_SCHEMA="https"
    export APP_USE_CACHE="true"
    export AUTH_PUBLIC_KEY="$(<"${material_dir}/auth-public.pem")"
    export AUTH_TOKEN_EXPIRE_SECONDS="900"
    export AUTH_SESSION_EXPIRE_SECONDS="2592000"
    export AUTH_SESSION_ABSOLUTE_EXPIRE_SECONDS="2592000"
    export AUTH_TOKEN_HEADER_NAME="Authorization"
    export AUTH_TOKEN_PREFIX="Bearer"
    export CACHE_WARM_ARTICLES_PAGE_SIZE="10"
    export COMPETENCY_MATRIX_QUESTION_SUGGESTION_ANONYMOUS_DAILY_LIMIT="10"
    export DB_DRIVER="postgresql+psycopg"
    export DB_EXPIRE_ON_COMMIT="false"
    export DB_HOST="postgres"
    export DB_LOG_QUERY_METRICS="false"
    export DB_MAX_OVERFLOW="20"
    export DB_NAME="competency_trainer_database"
    export DB_POOL_PRE_PING="true"
    export DB_POOL_SIZE="10"
    export DB_PORT="5432"
    export DB_SLOW_QUERY_LOG_STATEMENT_MAX_LENGTH="1000"
    export DB_SLOW_QUERY_LOG_THRESHOLD_MS="250"
    export DB_USER="competency_trainer"
    export FILES_ORPHAN_RETENTION_SECONDS="604800"
    export I18N_DEFAULT_LANGUAGE="ru"
    export LE_EMAIL="ops@example.test"
    export MINIO_CORS_MAX_AGE_SECONDS="300"
    export MINIO_HOST="minio"
    export MINIO_PORT="9000"
    export MINIO_PUBLIC_URL="https://s3.example.test"
    export MINIO_REGION="us-east-1"
    export MINIO_SECURE="false"
    export SENTRY_USE="false"
    export SSL_CERT="/certs/fullchain.pem"
    export SSL_KEY="/certs/privkey.pem"
    export TASKIQ_AUTH_SESSION_PRUNE_INTERVAL_SECONDS="86400"
    export TASKIQ_AGENT_AUDIT_PRUNE_INTERVAL_SECONDS="86400"
    export TASKIQ_CACHE_WARM_INTERVAL_SECONDS="3600"
    export TASKIQ_FILE_ORPHAN_PRUNE_INTERVAL_SECONDS="86400"
    export TASKIQ_RESULT_EXPIRE_SECONDS="3600"
    export VALKEY_HOST="valkey"
    export VALKEY_PORT="6379"
    export VPN_BIND_ADDRESS="10.77.0.1"
    export OWNER_INIT_PASSWORD="owner-password"
    export APP_SECRET_KEY="app-secret"
    export AUTH_PRIVATE_KEY="$(<"${material_dir}/auth-private.pem")"
    export DB_PASSWORD="postgres-password"
    export MINIO_ACCESS_KEY="minio-access"
    export MINIO_SECRET_KEY="minio-secret"
    export SENTRY_DSN=""
    export AGENT_ACCESS_ISSUING_CERTIFICATE="$(<"${material_dir}/issuing/agent-issuing-ca.cert.pem")"
    export AGENT_ACCESS_ISSUING_PRIVATE_KEY="$(<"${material_dir}/issuing/agent-issuing-ca.key.pem")"
    export AGENT_ACCESS_CERTIFICATE_CHAIN="$(<"${material_dir}/issuing/agent-certificate-chain.pem")"
}

run_deploy_env_configuration_check() {
    local compose_file="${repo_dir}/docker-compose.yml"
    local ci_workflow="${repo_dir}/.github/workflows/ci.yaml"
    local deploy_workflow="${repo_dir}/.github/workflows/_deploy.yaml"
    local backend_image_workflow="${repo_dir}/.github/workflows/_backend_docker_image_security.yaml"
    local frontend_image_workflow="${repo_dir}/.github/workflows/_frontend_docker_image_security.yaml"
    local nginx_image_workflow="${repo_dir}/.github/workflows/_nginx_docker_image_security.yaml"
    local manual_deploy_workflow="${repo_dir}/.github/workflows/deploy.yaml"
    local env_example="${repo_dir}/.env.example"
    local env_test="${repo_dir}/.env.test"
    local manifest_file="${repo_dir}/infra/deploy/runtime-env.manifest.json"
    local renderer="${repo_dir}/infra/scripts/render_deploy_env.py"
    local rendered_env

    require_command python3
    require_file_exists "$ci_workflow" "CI workflow"
    require_file_exists "$deploy_workflow" "private deploy workflow"
    require_file_exists "$backend_image_workflow" "private backend image security workflow"
    require_file_exists "$frontend_image_workflow" "private frontend image security workflow"
    require_file_exists "$nginx_image_workflow" "private nginx image security workflow"
    require_file_exists "$manual_deploy_workflow" "manual deploy workflow"
    require_file_exists "$manifest_file" "runtime environment manifest"
    require_file_exists "$renderer" "runtime environment renderer"

    require_file_not_contains "$ci_workflow" "runs-on:" "inline CI job runner"
    require_file_not_contains "$ci_workflow" "steps:" "inline CI job steps"
    require_file_contains "$ci_workflow" "dockerfile-lint:" "post-smoke Dockerfile lint job"
    require_file_contains "$ci_workflow" "trivy-config-scan:" "post-smoke Trivy config scan job"
    require_file_contains "$ci_workflow" "backend-docker-image-security:" "backend image security job"
    require_file_contains "$ci_workflow" "frontend-docker-image-security:" "frontend image security job"
    require_file_contains "$ci_workflow" "nginx-docker-image-security:" "nginx image security job"
    require_file_contains "$ci_workflow" "infra-security:" "post-smoke infrastructure security job"
    require_file_contains "$ci_workflow" "_backend_docker_image_security.yaml" "backend image security workflow"
    require_file_contains "$ci_workflow" "_frontend_docker_image_security.yaml" "frontend image security workflow"
    require_file_contains "$ci_workflow" "_nginx_docker_image_security.yaml" "nginx image security workflow"
    require_file_not_contains "$ci_workflow" "_deploy.yaml" "private deploy workflow call"
    require_file_not_contains "$ci_workflow" "uses: ./.github/workflows/_docker_image_security.yaml" "generic image security workflow"
    require_file_not_contains "$ci_workflow" "post-smoke-security:" "combined post-smoke security job"
    require_file_not_contains "$ci_workflow" "run-infra-security: true" "combined Docker security input"
    require_file_not_contains "$ci_workflow" "deploy:" "CI deploy job"
    require_file_contains "$manual_deploy_workflow" "workflow_dispatch:" "manual deploy trigger"
    require_file_not_contains "$manual_deploy_workflow" "push:" "automatic deploy trigger"
    require_file_not_contains "$manual_deploy_workflow" "needs:" "manual deploy CI needs graph"
    require_file_not_contains "$manual_deploy_workflow" "runs-on:" "inline manual deploy job runner"
    require_file_not_contains "$manual_deploy_workflow" "steps:" "inline manual deploy job steps"
    require_file_contains "$manual_deploy_workflow" "deploy:" "manual deploy job"
    require_file_contains "$manual_deploy_workflow" "if: github.ref == 'refs/heads/main'" "main-only deploy gate"
    require_file_contains "$manual_deploy_workflow" "uses: ./.github/workflows/_deploy.yaml" "private deploy workflow call"
    require_file_contains "$manual_deploy_workflow" "secrets: inherit" "deploy reusable workflow secrets pass-through"
    require_file_contains "$deploy_workflow" "environment: production" "production deployment environment approval"
    require_file_contains "$deploy_workflow" "vars.REMOTE_HOST" "remote host GitHub variable"
    require_file_contains "$deploy_workflow" "vars.REMOTE_USER" "remote user GitHub variable"
    require_file_contains "$deploy_workflow" "vars.REMOTE_PATH" "remote path GitHub variable"
    require_file_contains "$deploy_workflow" "secrets.SSH_PRIVATE_KEY" "SSH private key deploy secret"
    require_file_contains "$deploy_workflow" "cp -a Makefile docker-compose.yml backend/ frontend/ infra/ .env .deploy-payload/" "runtime file deploy sync"
    require_file_contains "$deploy_workflow" "make run" "remote stack restart"
    require_file_not_contains "$ci_workflow" "Create .env file from secrets" "manual secret echo env generation"
    require_file_not_contains "$ci_workflow" "REMOTE_HOST=\${{ secrets.REMOTE_HOST }}" "remote host runtime env entry"
    require_file_not_contains "$ci_workflow" "SSH_PRIVATE_KEY=" "SSH private key runtime env entry"
    require_file_not_contains "$ci_workflow" "DOCKER_PASSWORD=" "Docker password runtime env entry"
    require_file_not_contains "$ci_workflow" "CACHE_WARM_NOTES_PAGE_SIZE" "stale cache warm env name"
    require_file_not_contains "$ci_workflow" "issue_certificates" "deploy-time certificate issue input"
    require_file_not_contains "$ci_workflow" "make certbot-issue" "deploy-time certificate issue step"
    require_file_not_contains "$manual_deploy_workflow" "Create .env file from secrets" "manual secret echo env generation"
    require_file_not_contains "$manual_deploy_workflow" "REMOTE_HOST=\${{ secrets.REMOTE_HOST }}" "remote host runtime env entry"
    require_file_not_contains "$manual_deploy_workflow" "SSH_PRIVATE_KEY=" "SSH private key runtime env entry"
    require_file_not_contains "$manual_deploy_workflow" "DOCKER_PASSWORD=" "Docker password runtime env entry"
    require_file_not_contains "$manual_deploy_workflow" "CACHE_WARM_NOTES_PAGE_SIZE" "stale cache warm env name"
    require_file_not_contains "$deploy_workflow" "Create .env file from secrets" "manual secret echo env generation"
    require_file_not_contains "$deploy_workflow" "REMOTE_HOST=\${{ secrets.REMOTE_HOST }}" "remote host runtime env entry"
    require_file_not_contains "$deploy_workflow" "SSH_PRIVATE_KEY=" "SSH private key runtime env entry"
    require_file_not_contains "$deploy_workflow" "DOCKER_PASSWORD=" "Docker password runtime env entry"
    require_file_not_contains "$deploy_workflow" "CACHE_WARM_NOTES_PAGE_SIZE" "stale cache warm env name"

    require_file_contains "$manifest_file" '"CACHE_WARM_ARTICLES_PAGE_SIZE"' "cache warm articles page size manifest entry"
    require_file_contains "$manifest_file" '"TASKIQ_AUTH_SESSION_PRUNE_INTERVAL_SECONDS"' "auth session prune interval manifest entry"
    require_file_contains "$manifest_file" '"FILES_ORPHAN_RETENTION_SECONDS"' "file orphan retention manifest entry"
    require_file_contains "$manifest_file" '"TASKIQ_FILE_ORPHAN_PRUNE_INTERVAL_SECONDS"' "file orphan prune interval manifest entry"
    require_file_contains "$manifest_file" '"AUTH_SESSION_ABSOLUTE_EXPIRE_SECONDS"' "auth session absolute expiry manifest entry"
    require_file_not_contains "$manifest_file" "CACHE_WARM_NOTES_PAGE_SIZE" "stale cache warm manifest entry"
    require_file_not_contains "$manifest_file" "REMOTE_HOST" "deploy remote host manifest entry"
    require_file_not_contains "$manifest_file" "SSH_PRIVATE_KEY" "deploy SSH key manifest entry"
    require_file_not_contains "$manifest_file" "DOCKER_PASSWORD" "Docker password manifest entry"
    require_file_not_contains "$manifest_file" "AGENT_API_" "removed separate Agent API manifest entry"

    require_file_not_contains "$env_example" "REMOTE_HOST=" "remote host local env example entry"
    require_file_not_contains "$env_example" "SSH_PRIVATE_KEY=" "SSH private key local env example entry"
    require_file_not_contains "$env_example" "DOCKER_PASSWORD=" "Docker password local env example entry"
    require_file_not_contains "$env_example" "DOCKER_REGISTRY=" "Docker registry local env example entry"
    require_file_not_contains "$env_example" "DOCKER_USERNAME=" "Docker username local env example entry"
    require_file_not_contains "$env_example" "AGENT_API_" "removed separate Agent API env example entry"
    require_file_not_contains "$env_test" "AGENT_API_" "removed separate Agent API test env entry"

    require_file_not_contains "$compose_file" "\${DOCKER_REGISTRY}" "runtime Docker registry interpolation"
    require_file_not_contains "$compose_file" "\${DOCKER_USERNAME}" "runtime Docker username interpolation"
    require_file_contains "$compose_file" 'image: "competency_trainer_application:${IMAGE_TAG:?IMAGE_TAG must be set}"' "required local backend image tag"
    require_file_contains "$compose_file" 'image: "competency_trainer_frontend:${IMAGE_TAG:?IMAGE_TAG must be set}"' "required local frontend image tag"
    require_file_contains "$compose_file" 'image: "competency_trainer_minio:${IMAGE_TAG:?IMAGE_TAG must be set}"' "required local MinIO image tag"
    require_file_contains "$compose_file" 'image: "competency_trainer_nginx:${IMAGE_TAG:?IMAGE_TAG must be set}"' "required local nginx image tag"
    require_no_latest_image_tags \
        "$compose_file" \
        "$backend_image_workflow" \
        "$frontend_image_workflow" \
        "$nginx_image_workflow"

    rendered_env="$(mktemp)"
    local material_dir
    local compose_secrets_dir
    material_dir="$(mktemp -d)"
    compose_secrets_dir="$(mktemp -d)"
    create_test_runtime_material "$material_dir"
    echo "Rendering a real multiline deployment environment."
    (
        export_test_runtime_environment "$material_dir"
        export GITHUB_ENV_VARS_JSON='{}'
        export GITHUB_SECRETS_JSON='{}'
        python3 "$renderer" --manifest "$manifest_file" --output "$rendered_env"
    )
    require_file_contains "$rendered_env" 'CACHE_WARM_ARTICLES_PAGE_SIZE="10"' "rendered cache warm articles page size"
    require_file_contains "$rendered_env" 'TASKIQ_AUTH_SESSION_PRUNE_INTERVAL_SECONDS="86400"' "rendered auth session prune interval"
    require_file_contains "$rendered_env" 'FILES_ORPHAN_RETENTION_SECONDS="604800"' "rendered file orphan retention"
    require_file_contains "$rendered_env" 'TASKIQ_FILE_ORPHAN_PRUNE_INTERVAL_SECONDS="86400"' "rendered file orphan prune interval"
    require_file_contains "$rendered_env" 'AUTH_SESSION_EXPIRE_SECONDS="2592000"' "rendered auth session expiry"
    require_file_contains "$rendered_env" 'AUTH_SESSION_ABSOLUTE_EXPIRE_SECONDS="2592000"' "rendered auth session absolute expiry"
    require_file_contains "$rendered_env" 'MINIO_REGION="us-east-1"' "rendered MinIO region"
    require_file_contains "$rendered_env" 'MINIO_PUBLIC_URL="https://s3.example.test"' "rendered public MinIO URL"
    require_file_contains "$rendered_env" 'AGENT_ACCESS_ISSUING_CERTIFICATE="-----BEGIN CERTIFICATE-----\n' "rendered agent issuing certificate secret"
    require_file_contains "$rendered_env" 'AUTH_PRIVATE_KEY="-----BEGIN PRIVATE KEY-----\n' "rendered escaped multiline private key"
    require_file_not_contains "$rendered_env" "CACHE_WARM_NOTES_PAGE_SIZE" "stale cache warm rendered env entry"
    require_file_not_contains "$rendered_env" "REMOTE_HOST" "deploy remote host rendered env entry"
    require_file_not_contains "$rendered_env" "SSH_PRIVATE_KEY" "deploy SSH key rendered env entry"
    require_file_not_contains "$rendered_env" "DOCKER_PASSWORD" "Docker password rendered env entry"
    require_file_not_contains "$rendered_env" "AGENT_API_" "removed separate Agent API rendered env entry"
    echo "Materializing and validating rendered Compose secrets."
    (
        set -a
        . "$rendered_env"
        set +a
        export COMPOSE_SECRETS_DIR="$compose_secrets_dir"
        # shellcheck source=compose_secrets.sh
        . "${repo_dir}/infra/scripts/compose_secrets.sh"
        prepare_compose_secret_files
        openssl pkey -in "$COMPOSE_AUTH_PRIVATE_KEY_FILE" -noout >/dev/null
        openssl x509 -in "$COMPOSE_AGENT_ISSUING_CERTIFICATE_FILE" -noout >/dev/null
        openssl pkey -in "$COMPOSE_AGENT_ISSUING_PRIVATE_KEY_FILE" -noout >/dev/null
        openssl verify \
            -CAfile "${material_dir}/offline/agent-root-ca.cert.pem" \
            "$COMPOSE_AGENT_ISSUING_CERTIFICATE_FILE" >/dev/null
    )
    rm -rf "$material_dir" "$compose_secrets_dir"
    rm -f "$rendered_env"

    if (
        export IMAGE_TAG="security-check-sha"
        export GITHUB_ENV_VARS_JSON='{}'
        export GITHUB_SECRETS_JSON='{}'
        python3 "$renderer" --manifest "$manifest_file" --output "$rendered_env"
    ) >/dev/null 2>&1; then
        echo "Renderer accepted missing required deployment values." >&2
        rm -f "$rendered_env"
        exit 1
    fi
    rm -f "$rendered_env"
}

run_private_panel_configuration_check() {
    local compose_file="${repo_dir}/docker-compose.yml"
    local env_example="${repo_dir}/.env.example"
    local manifest_file="${repo_dir}/infra/deploy/runtime-env.manifest.json"
    local nginx_template="${repo_dir}/infra/nginx/templates/site.conf.template"
    local run_script="${repo_dir}/infra/scripts/run.sh"

    require_file_contains "$env_example" "VPN_BIND_ADDRESS=" "VPN bind address example"
    require_file_contains "$manifest_file" "VPN_BIND_ADDRESS" "VPN bind address deployment variable"
    require_file_contains "$run_script" "VPN_BIND_ADDRESS must be set" "VPN bind address startup guard"

    require_file_contains "$compose_file" '"${VPN_BIND_ADDRESS}:18081:18081"' "MinIO Console VPN-only port binding"
    require_file_contains "$compose_file" '"${VPN_BIND_ADDRESS}:18082:18082"' "Databasus VPN-only port binding"
    require_file_contains "$compose_file" '"${VPN_BIND_ADDRESS}:18083:18083"' "Agent API VPN-only port binding"
    require_file_not_contains "$compose_file" "-d s3-panel.\${APP_DOMAIN}" "public MinIO Console certificate domain"
    require_file_not_contains "$compose_file" "-d backup.\${APP_DOMAIN}" "public Databasus certificate domain"

    require_file_not_contains "$nginx_template" "server_name s3-panel.\${APP_DOMAIN};" "public MinIO Console virtual host"
    require_file_not_contains "$nginx_template" "server_name backup.\${APP_DOMAIN};" "public Databasus virtual host"
    require_file_contains "$nginx_template" "listen 18081;" "private MinIO Console listener"
    require_file_contains "$nginx_template" "listen 18082;" "private Databasus listener"
    require_file_contains "$nginx_template" "listen 18083 ssl;" "private mTLS Agent API listener"
    require_file_contains "$nginx_template" "access_log /dev/stdout agent_api_json;" "structured Agent API access log"
    require_file_contains "${repo_dir}/infra/nginx/nginx.conf" "log_format privacy_safe '\$request_method \$uri \$server_protocol \$status';" "privacy-safe main access log format"
    require_file_contains "${repo_dir}/infra/nginx/nginx.conf" "access_log /dev/stdout privacy_safe;" "privacy-safe main access log selection"
    require_file_not_contains "${repo_dir}/infra/nginx/nginx.conf" "\$request_uri" "raw request URI in access log configuration"
    require_file_not_contains "${repo_dir}/infra/nginx/nginx.conf" "\$args" "raw query arguments in access log configuration"
    require_file_contains "${repo_dir}/infra/nginx/nginx.conf" "log_format agent_api_json escape=json" "Agent API JSON log format"
    require_file_contains "${repo_dir}/infra/nginx/nginx.conf" '"clientVerify":"$ssl_client_verify"' "client verification log field"
    require_file_contains "${repo_dir}/infra/nginx/nginx.conf" '"clientFingerprint":"$ssl_client_fingerprint"' "client fingerprint log field"
}

run_healthcheck_configuration_check() {
    local compose_file="${repo_dir}/docker-compose.yml"
    local deploy_workflow="${repo_dir}/.github/workflows/_deploy.yaml"
    local nginx_template="${repo_dir}/infra/nginx/templates/site.conf.template"
    local nginx_entrypoint="${repo_dir}/infra/nginx/entrypoint.sh"
    local nginx_healthcheck="${repo_dir}/infra/nginx/healthcheck.sh"
    local run_script="${repo_dir}/infra/scripts/run.sh"
    local backend_start_script="${repo_dir}/backend/start_application.sh"
    local frontend_server="${repo_dir}/frontend/src/server-app.ts"
    local compose_secret_script="${repo_dir}/infra/scripts/compose_secrets.sh"
    local agent_api_checker="${repo_dir}/infra/scripts/check_agent_api_invariants.py"
    local rendered_compose
    local rendered_nginx
    local material_dir

    require_command docker
    require_command python3
    if ! docker compose version >/dev/null 2>&1; then
        echo "docker compose plugin could not be found." >&2
        exit 2
    fi

    rendered_compose="$(mktemp)"
    rendered_nginx="$(mktemp)"
    material_dir="$(mktemp -d)"
    create_test_runtime_material "$material_dir"
    (
        export_test_runtime_environment "$material_dir"
        export COMPOSE_SECRETS_DIR
        COMPOSE_SECRETS_DIR="$(mktemp -d)"
        trap 'rm -rf "$COMPOSE_SECRETS_DIR"' EXIT
        # shellcheck source=compose_secrets.sh
        . "$compose_secret_script"
        prepare_compose_secret_files
        docker compose -f "$compose_file" config --format json >"$rendered_compose"
    )
    {
        cat "${repo_dir}/infra/nginx/nginx.conf"
        sed \
            -e 's|${ACTIVE_BACKEND_SLOT}|backend-blue|g' \
            -e 's|${ACTIVE_FRONTEND_SLOT}|frontend-blue|g' \
            -e 's|${APP_DOMAIN}|example.test|g' \
            -e 's|${MINIO_PUBLIC_URL}|https://s3.example.test|g' \
            -e 's|${SSL_CERT}|/certs/fullchain.pem|g' \
            -e 's|${SSL_KEY}|/certs/privkey.pem|g' \
            "$nginx_template"
    } >"$rendered_nginx"
    python3 "$agent_api_checker" \
        --compose-json "$rendered_compose" \
        --nginx-config "$rendered_nginx" \
        --codex-config "${repo_dir}/.codex/config.toml" \
        --vpn-address "10.77.0.1"
    rm -rf "$material_dir"
    rm -f "$rendered_compose" "$rendered_nginx"

    require_file_contains "$compose_file" "backend-blue:" "blue backend service"
    require_file_contains "$compose_file" "backend-green:" "green backend service"
    require_file_contains "$compose_file" "frontend-blue:" "blue frontend service"
    require_file_contains "$compose_file" "frontend-green:" "green frontend service"
    require_file_contains "$compose_file" "backend-init:" "one-shot backend init service"
    require_file_contains "$compose_file" "/api/healthcheck/ready" "backend readiness healthcheck"
    require_file_contains "$compose_file" "/healthz" "frontend healthcheck"
    require_file_contains "$nginx_healthcheck" "/nginx-healthz" "nginx healthcheck endpoint"
    require_file_contains "$compose_file" "MINIO_API_CORS_ALLOW_ORIGIN: \${APP_URL_SCHEMA}://\${APP_DOMAIN}" "MinIO public file CORS origin"
    require_file_contains "$compose_file" 'user: "10001:10001"' "backend explicit non-root UID/GID"
    require_file_contains "$compose_file" 'user: "1000:1000"' "frontend explicit non-root UID/GID"
    require_file_contains "$compose_file" 'user: "101:101"' "nginx explicit non-root UID/GID"
    require_file_contains "$compose_file" 'user: "70:70"' "Postgres explicit non-root UID/GID"
    require_file_contains "$compose_file" 'user: "999:999"' "Valkey explicit non-root UID/GID"
    require_file_contains "$compose_file" 'user: "10002:10002"' "MinIO explicit non-root UID/GID"
    require_compose_service_contains "$compose_file" "backend-blue" "restart: unless-stopped" "backend blue restart policy"
    require_compose_service_contains "$compose_file" "backend-green" "restart: unless-stopped" "backend green restart policy"
    require_compose_service_contains "$compose_file" "taskiq-worker" "restart: unless-stopped" "TaskIQ worker restart policy"
    require_compose_service_contains "$compose_file" "taskiq-scheduler" "restart: unless-stopped" "TaskIQ scheduler restart policy"
    require_compose_service_contains "$compose_file" "valkey" "restart: unless-stopped" "Valkey restart policy"
    require_compose_service_contains "$compose_file" "postgres" "restart: unless-stopped" "PostgreSQL restart policy"
    require_compose_service_contains "$compose_file" "minio" "restart: unless-stopped" "MinIO restart policy"
    require_compose_service_contains "$compose_file" "nginx" "restart: always" "nginx restart policy"
    require_compose_service_contains "$compose_file" "databasus" "restart: unless-stopped" "Databasus restart policy"
    require_file_contains "$compose_file" "dockerfile: infra/minio/Dockerfile" "MinIO non-root wrapper Dockerfile"
    require_file_contains "$compose_file" 'command: ["server", "/data", "--console-address", ":9001"]' "MinIO exec-form command"
    require_file_contains "$compose_file" "read_only: true" "app-owned read-only root filesystems"
    require_file_contains "$compose_file" "cap_drop:" "runtime Linux capability drop"
    require_file_contains "$compose_file" "no-new-privileges:true" "runtime no-new-privileges"
    require_file_contains "$compose_file" "/tmp:mode=1777,uid=10001,gid=10001" "backend writable tmpfs"
    require_file_contains "$compose_file" "/tmp:mode=1777,uid=1000,gid=1000" "frontend writable tmpfs"
    require_file_contains "$compose_file" "/tmp:mode=1777,uid=101,gid=101" "nginx writable tmpfs"
    require_file_contains "$compose_file" "command: bash start_application.sh taskiq-worker" "TaskIQ worker read-only-compatible entrypoint"
    require_file_contains "$compose_file" "command: bash start_application.sh taskiq-scheduler" "TaskIQ scheduler read-only-compatible entrypoint"
    require_file_contains "$compose_file" "./infra/nginx/certs:/certs:ro" "nginx read-only certificate volume"
    require_file_contains "$compose_file" "APP_SECRET_KEY_FILE: /run/secrets/app_secret_key" "backend app secret file"
    require_file_contains "$compose_file" "AUTH_PRIVATE_KEY_FILE: /run/secrets/auth_private_key" "backend private key secret file"
    require_file_contains "$compose_file" "AUTH_SESSION_EXPIRE_SECONDS: \${AUTH_SESSION_EXPIRE_SECONDS}" "backend auth session lifetime env"
    require_file_contains "$compose_file" "AUTH_SESSION_ABSOLUTE_EXPIRE_SECONDS: \${AUTH_SESSION_ABSOLUTE_EXPIRE_SECONDS}" "backend auth session absolute lifetime env"
    require_file_contains "$compose_file" "DB_PASSWORD_FILE: /run/secrets/db_password" "backend database secret file"
    require_file_contains "$compose_file" "POSTGRES_PASSWORD_FILE: /run/secrets/db_password" "Postgres password secret file"
    require_file_contains "$compose_file" "MINIO_ACCESS_KEY_FILE: /run/secrets/minio_access_key" "backend MinIO access key secret file"
    require_file_contains "$compose_file" "MINIO_SECRET_KEY_FILE: /run/secrets/minio_secret_key" "backend MinIO secret key secret file"
    require_file_contains "$compose_file" "OWNER_INIT_PASSWORD_FILE: /run/secrets/owner_init_password" "backend owner password secret file"
    require_file_contains "$compose_file" "SENTRY_DSN_FILE: /run/secrets/sentry_dsn" "backend Sentry DSN secret file"
    require_file_contains "$compose_file" "file: \${COMPOSE_APP_SECRET_KEY_FILE:?" "Compose app secret file source"
    require_file_contains "$compose_file" "file: \${COMPOSE_AUTH_PRIVATE_KEY_FILE:?" "Compose private key secret file source"
    require_file_contains "$compose_file" "file: \${COMPOSE_DB_PASSWORD_FILE:?" "Compose database password secret file source"
    require_file_contains "$compose_file" "file: \${COMPOSE_MINIO_ACCESS_KEY_FILE:?" "Compose MinIO access key secret file source"
    require_file_contains "$compose_file" "file: \${COMPOSE_MINIO_SECRET_KEY_FILE:?" "Compose MinIO secret key secret file source"
    require_file_contains "$compose_file" "file: \${COMPOSE_OWNER_INIT_PASSWORD_FILE:?" "Compose owner password secret file source"
    require_file_contains "$compose_file" "file: \${COMPOSE_SENTRY_DSN_FILE:?" "Compose Sentry DSN secret file source"
    require_file_contains "$compose_secret_script" "COMPOSE_AGENT_ISSUING_PRIVATE_KEY_FILE required" "agent issuing private key secret preparation"

    require_file_contains "$nginx_template" "resolver 127.0.0.11" "Docker DNS resolver"
    require_file_contains "$nginx_entrypoint" "Rendered nginx configuration is empty." "fail-closed nginx rendering"
    require_file_contains "$nginx_entrypoint" "mv \"\$temporary_file\" \"\$rendered_file\"" "atomic nginx configuration switch"
    require_file_contains "$compose_file" 'command: ["/usr/local/bin/competency-trainer-nginx-entrypoint"]' "nginx entrypoint command"
    require_file_contains "$nginx_template" "server \${ACTIVE_BACKEND_SLOT}:8080 resolve;" "active backend slot"
    require_file_contains "$nginx_template" "server \${ACTIVE_FRONTEND_SLOT}:4000 resolve;" "active frontend slot"
    require_file_contains "$nginx_template" "connect-src 'self' \${MINIO_PUBLIC_URL}" "public MinIO file CSP"
    require_file_contains "$nginx_template" "img-src 'self' data: blob: \${MINIO_PUBLIC_URL}; font-src 'self' data:;" "main site CSP with upload/blob previews"
    require_file_contains "$nginx_template" "style-src 'self' 'nonce-\$request_id'; script-src 'self' 'nonce-\$request_id'; script-src-attr 'none'" "main site nonce CSP without inline style attributes"
    require_file_contains "$nginx_template" "proxy_set_header X-CSP-Nonce" "frontend CSP nonce proxy header"
    require_frontend_location_has_no_proxy_headers "$nginx_template"
    require_file_contains "$nginx_template" "location ^~ /api/docs" "public API docs CSP location"
    require_file_contains "$nginx_template" "zone=auth_refresh_per_ip" "auth refresh rate limit zone"
    require_file_contains "$nginx_template" "location = /api/auth/refresh" "auth refresh exact rate-limited location"
    require_file_contains "$nginx_template" "img-src 'self' data: \${MINIO_PUBLIC_URL} https://cdn.jsdelivr.net" "Swagger UI image CSP"
    require_file_contains "$nginx_template" "font-src 'self' data: https://cdn.jsdelivr.net" "Swagger UI font CSP"
    require_file_contains "$nginx_template" "script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net" "Swagger UI script CSP"
    require_file_contains "$nginx_template" "style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net" "Swagger UI style CSP"
    require_file_contains "$nginx_template" "location = /nginx-healthz" "nginx health endpoint"
    require_file_contains "$run_script" "ACTIVE_DEPLOY_SLOT" "active deploy slot tracking"
    require_file_contains "$run_script" "compose_up_wait --force-recreate nginx" "static nginx recreation"
    require_file_contains "$run_script" "--wait-timeout" "health-gated compose startup"
    require_file_contains "$run_script" "--remove-orphans" "removed service cleanup"
    require_file_contains "$run_script" "backend-init" "backend init deploy step"
    require_file_contains "$run_script" "prepare_minio_volume_permissions" "MinIO non-root volume ownership preparation"
    require_file_contains "$run_script" "chown -R 10002:10002 /data" "MinIO volume ownership repair"
    require_file_contains "$run_script" "prepare_compose_secret_files" "host-side Compose secret file preparation"
    require_file_contains "$compose_secret_script" "COMPOSE_SENTRY_DSN_FILE allow-empty" "empty Sentry DSN secret file support"
    require_file_contains "$compose_secret_script" "chmod 444 \"\$secret_file_path\"" "non-root-readable Compose secret files"
    require_file_contains "$backend_start_script" "AUTH_PRIVATE_KEY AUTH_PUBLIC_KEY" "runtime key newline normalization"
    require_file_not_contains "$backend_start_script" "agent-api)" "removed Agent API startup action"

    require_file_contains "$frontend_server" "app.get('/healthz'" "frontend health endpoint"
    require_file_contains "$deploy_workflow" "frontend/" "frontend deploy sync"
}

run_runtime_container_security_check() {
    local compose_file="${repo_dir}/docker-compose.yml"
    local docker_lint_script="${repo_dir}/infra/scripts/docker_lint.sh"
    local root_dockerignore="${repo_dir}/.dockerignore"
    local nginx_conf="${repo_dir}/infra/nginx/nginx.conf"
    local nginx_template="${repo_dir}/infra/nginx/templates/site.conf.template"

    require_file_contains "$docker_lint_script" "infra/minio/Dockerfile" "MinIO Dockerfile lint coverage"
    require_file_contains "$root_dockerignore" ".deploy-state" "deploy secret state excluded from root Docker build context"
    require_file_contains "$root_dockerignore" ".deploy-payload" "deploy payload excluded from root Docker build context"
    require_file_contains "$root_dockerignore" "infra/nginx/certs" "runtime TLS material excluded from root Docker build context"
    require_no_inspect_visible_secret_environment "$compose_file"
    require_no_unapproved_network_literals \
        "hardcoded IP literal outside Docker resolver or self-healthchecks" \
        "([0-9]{1,3}\.){3}[0-9]{1,3}" \
        "$compose_file" \
        "$nginx_template"
    require_no_unapproved_network_literals \
        "localhost reference outside self-healthchecks" \
        "localhost" \
        "$compose_file" \
        "$nginx_template"
    require_no_container_file_logs \
        "$compose_file" \
        "$nginx_conf" \
        "$nginx_template" \
        "${repo_dir}/backend/Dockerfile" \
        "${repo_dir}/backend/start_application.sh" \
        "${repo_dir}/frontend/Dockerfile" \
        "${repo_dir}/infra/minio/Dockerfile" \
        "${repo_dir}/infra/nginx/Dockerfile"
}

run_certbot_configuration_check() {
    local compose_file="${repo_dir}/docker-compose.yml"
    local ci_workflow="${repo_dir}/.github/workflows/ci.yaml"
    local deploy_workflow="${repo_dir}/.github/workflows/_deploy.yaml"
    local manual_deploy_workflow="${repo_dir}/.github/workflows/deploy.yaml"
    local makefile="${repo_dir}/Makefile"
    local nginx_template="${repo_dir}/infra/nginx/templates/site.conf.template"
    local run_script="${repo_dir}/infra/scripts/run.sh"
    local tls_script="${repo_dir}/infra/scripts/tls.sh"

    require_file_exists "$tls_script" "TLS helper script"
    require_file_contains "$compose_file" "cert-sync:" "certificate sync service"
    require_file_contains "$compose_file" "certbot-www:/var/www/certbot:ro" "nginx read-only certbot challenge volume"
    require_file_contains "$compose_file" "certbot-www:/var/www/certbot" "certbot challenge volume"
    require_file_contains "$compose_file" "./infra/nginx/certs:/certs" "nginx certificate volume"
    require_file_contains "$compose_file" "letsencrypt:/etc/letsencrypt" "certbot certificate volume"
    require_file_contains "$nginx_template" "root /var/www/certbot;" "HTTP-01 challenge webroot"
    require_file_contains "$run_script" "sync_certificates" "deploy certificate sync step"
    require_file_contains "$makefile" "certbot-issue" "certbot issue target"
    require_file_contains "$makefile" "certbot-renew" "certbot renew target"
    require_file_contains "$makefile" "certbot-sync" "certbot sync target"
    require_file_contains "$compose_file" "-d agent.\${APP_DOMAIN}" "Agent API hostname certificate SAN"
    require_file_contains "$tls_script" '-d "agent.${APP_DOMAIN}"' "Agent API hostname TLS issue argument"
    require_file_not_contains "$compose_file" "-d mcp.\${APP_DOMAIN}" "legacy MCP hostname certificate SAN"
    require_file_not_contains "$ci_workflow" "issue_certificates" "deploy-time certificate issue input"
    require_file_not_contains "$ci_workflow" "make certbot-issue" "deploy-time certificate issue step"
    require_file_contains "$manual_deploy_workflow" "issue_certificates:" "manual deploy certificate issue input"
    require_file_contains \
        "$manual_deploy_workflow" \
        'issue_certificates: ${{ inputs.issue_certificates }}' \
        "manual deploy certificate issue input forwarding"
    require_file_contains "$deploy_workflow" "issue_certificates:" "reusable deploy certificate issue input"
    require_file_contains \
        "$deploy_workflow" \
        'if: ${{ inputs.issue_certificates }}' \
        "conditional deploy certificate issue step"
    require_file_contains "$deploy_workflow" "make certbot-issue" "deploy-time certificate issue command"
    require_file_pattern_before \
        "$deploy_workflow" \
        "make certbot-issue" \
        "make run" \
        "certificate issue and stack restart order"
}

run_agent_ca_helper_check() {
    local ca_script="${repo_dir}/infra/scripts/agent_ca.sh"
    local ca_temp_dir
    local issuing_text

    require_command openssl
    require_file_exists "$ca_script" "agent CA helper"
    ca_temp_dir="$(mktemp -d)"
    bash "$ca_script" init "${ca_temp_dir}/offline" "${ca_temp_dir}/issuing" >/dev/null
    bash "$ca_script" client-csr test-agent "${ca_temp_dir}/client" >/dev/null

    test "$(stat -c '%a' "${ca_temp_dir}/offline/agent-root-ca.key.pem" 2>/dev/null || stat -f '%Lp' "${ca_temp_dir}/offline/agent-root-ca.key.pem")" = "600"
    test "$(stat -c '%a' "${ca_temp_dir}/issuing/agent-issuing-ca.key.pem" 2>/dev/null || stat -f '%Lp' "${ca_temp_dir}/issuing/agent-issuing-ca.key.pem")" = "600"
    test "$(stat -c '%a' "${ca_temp_dir}/client/test-agent.key.pem" 2>/dev/null || stat -f '%Lp' "${ca_temp_dir}/client/test-agent.key.pem")" = "600"
    openssl verify \
        -CAfile "${ca_temp_dir}/offline/agent-root-ca.cert.pem" \
        "${ca_temp_dir}/issuing/agent-issuing-ca.cert.pem" >/dev/null
    issuing_text="$(openssl x509 -in "${ca_temp_dir}/issuing/agent-issuing-ca.cert.pem" -noout -text)"
    if ! grep -Fq "CA:TRUE, pathlen:0" <<<"$issuing_text"; then
        echo "Agent issuing certificate is not a pathlen:0 CA." >&2
        rm -rf "$ca_temp_dir"
        exit 1
    fi
    if [ -e "${ca_temp_dir}/issuing/agent-root-ca.key.pem" ]; then
        echo "Offline root private key leaked into the issuing directory." >&2
        rm -rf "$ca_temp_dir"
        exit 1
    fi
    if bash "$ca_script" client-csr forbidden-agent "$repo_dir" >/dev/null 2>&1; then
        echo "Agent CA helper allowed client key material inside the repository." >&2
        rm -rf "$ca_temp_dir"
        exit 1
    fi
    rm -rf "$ca_temp_dir"
}

run_minio_image_check() {
    require_command docker

    minio_check_image_tag="competency-trainer-minio-security-check:$(date +%s)-$$"
    minio_check_temp_dir="$(mktemp -d)"
    trap cleanup_security_check_images EXIT

    mkdir -p "${minio_check_temp_dir}/secrets"
    printf '%s' "minioadmin" >"${minio_check_temp_dir}/secrets/minio_access_key"
    printf '%s' "minioadminsecret" >"${minio_check_temp_dir}/secrets/minio_secret_key"

    docker build \
        -f "${repo_dir}/infra/minio/Dockerfile" \
        -t "$minio_check_image_tag" \
        "$repo_dir"

    docker run --rm \
        --user 10002:10002 \
        -v "${minio_check_temp_dir}/secrets:/run/secrets:ro" \
        "$minio_check_image_tag" \
        server --help >"${minio_check_temp_dir}/minio-help.txt"

    require_file_contains "${minio_check_temp_dir}/minio-help.txt" "NAME:" "MinIO server help output"

    docker run --rm \
        --user 10002:10002 \
        --entrypoint sh \
        "$minio_check_image_tag" \
        -c 'test "$(id -u):$(id -g)" = "10002:10002" && test -w /data'
}

issue_test_client_certificate() {
    local certificate_name="$1"
    local ca_certificate="$2"
    local ca_key="$3"
    local validity_days="$4"
    local output_dir="$5"
    local extension_file="${output_dir}/${certificate_name}.ext"

    openssl genpkey \
        -algorithm EC \
        -pkeyopt ec_paramgen_curve:P-256 \
        -pkeyopt ec_param_enc:named_curve \
        -out "${output_dir}/${certificate_name}.key" 2>/dev/null
    openssl req \
        -new \
        -sha256 \
        -key "${output_dir}/${certificate_name}.key" \
        -subj "/CN=${certificate_name}" \
        -out "${output_dir}/${certificate_name}.csr" 2>/dev/null
    printf '%s\n' \
        "basicConstraints=critical,CA:FALSE" \
        "keyUsage=critical,digitalSignature" \
        "extendedKeyUsage=clientAuth" >"$extension_file"
    openssl x509 \
        -req \
        -sha256 \
        -in "${output_dir}/${certificate_name}.csr" \
        -CA "$ca_certificate" \
        -CAkey "$ca_key" \
        -CAserial "${output_dir}/${certificate_name}.serial" \
        -CAcreateserial \
        -days "$validity_days" \
        -extfile "$extension_file" \
        -out "${output_dir}/${certificate_name}.crt" >/dev/null 2>&1
}

generate_agent_test_certificate() {
    local certificate_name="$1"
    local validity="$2"
    local material_dir="$3"
    local output_dir="$4"

    docker run --rm \
        --user "$(id -u):$(id -g)" \
        --entrypoint python \
        -v "${material_dir}:/material:ro" \
        -v "${output_dir}:/output" \
        -v "${repo_dir}/infra/scripts/generate_agent_test_certificate.py:/infra/generate_agent_test_certificate.py:ro" \
        "$agent_api_check_image_tag" \
        /infra/generate_agent_test_certificate.py \
        /material/issuing/agent-issuing-ca.cert.pem \
        /material/issuing/agent-issuing-ca.key.pem \
        "/output/${certificate_name}.crt" \
        "/output/${certificate_name}.key" \
        "$certificate_name" \
        "$validity"
}

agent_request_status() {
    local port="$1"
    local certificate="$2"
    local key="$3"
    local method="$4"
    local path="$5"

    curl \
        --connect-timeout 3 \
        --max-time 10 \
        -k \
        -sS \
        -o /dev/null \
        -w '%{http_code}' \
        --cert "$certificate" \
        --key "$key" \
        -X "$method" \
        -H 'X-Agent-Client-Certificate: caller-controlled-value' \
        "https://127.0.0.1:${port}${path}"
}

run_nginx_syntax_check() {
    local cert_dir
    local material_dir
    local rendered_env
    local compose_secrets_dir
    local private_port
    local public_port
    local no_certificate_status
    local valid_certificate_status
    local rejected_certificate_status
    local public_spoof_status
    local public_internal_status
    local public_agent_status
    local nginx_logs
    local probe_logs
    local revoked_fingerprint
    local attempt

    require_command docker
    require_command openssl
    require_command curl

    nginx_check_temp_dir="$(mktemp -d)"
    cert_dir="${nginx_check_temp_dir}/certs"
    material_dir="${nginx_check_temp_dir}/material"
    rendered_env="${nginx_check_temp_dir}/runtime.env"
    compose_secrets_dir="${nginx_check_temp_dir}/compose-secrets"
    nginx_check_image_tag="competency-trainer-nginx-security-check:$(date +%s)-$$"
    agent_api_check_image_tag="competency-trainer-backend-agent-edge-check:$(date +%s)-$$"
    nginx_check_container_name="competency-trainer-nginx-agent-api-check-$(date +%s)-$$"
    agent_api_probe_container_name="competency-trainer-agent-api-probe-$(date +%s)-$$"
    nginx_check_network_name="competency-trainer-agent-api-edge-check-$(date +%s)-$$"
    mkdir -p "$cert_dir" "$compose_secrets_dir"
    trap cleanup_security_check_images EXIT

    create_test_runtime_material "$material_dir"
    (
        export_test_runtime_environment "$material_dir"
        export GITHUB_ENV_VARS_JSON='{}'
        export GITHUB_SECRETS_JSON='{}'
        python3 "${repo_dir}/infra/scripts/render_deploy_env.py" \
            --manifest "${repo_dir}/infra/deploy/runtime-env.manifest.json" \
            --output "$rendered_env"
    )
    set -a
    . "$rendered_env"
    set +a
    export COMPOSE_SECRETS_DIR="$compose_secrets_dir"
    # shellcheck source=compose_secrets.sh
    . "${repo_dir}/infra/scripts/compose_secrets.sh"
    prepare_compose_secret_files

    openssl req \
        -x509 \
        -nodes \
        -newkey rsa:2048 \
        -keyout "${cert_dir}/server.key" \
        -out "${cert_dir}/server.crt" \
        -days 1 \
        -subj "/CN=example.test" >/dev/null 2>&1
    docker build \
        -f "${repo_dir}/backend/Dockerfile" \
        -t "$agent_api_check_image_tag" \
        "${repo_dir}/backend"
    generate_agent_test_certificate valid-agent valid "$material_dir" "$cert_dir"
    generate_agent_test_certificate revoked-agent valid "$material_dir" "$cert_dir"
    generate_agent_test_certificate expired-agent expired "$material_dir" "$cert_dir"
    openssl req \
        -x509 \
        -nodes \
        -newkey ec \
        -pkeyopt ec_paramgen_curve:P-256 \
        -keyout "${cert_dir}/wrong-ca.key" \
        -out "${cert_dir}/wrong-ca.crt" \
        -days 1 \
        -subj "/CN=Wrong Agent Test CA" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
    issue_test_client_certificate \
        wrong-ca-agent \
        "${cert_dir}/wrong-ca.crt" \
        "${cert_dir}/wrong-ca.key" \
        1 \
        "$cert_dir"
    chmod 644 "${cert_dir}"/*.key "${cert_dir}"/*.crt
    revoked_fingerprint="$(openssl x509 \
        -in "${cert_dir}/revoked-agent.crt" \
        -noout \
        -fingerprint \
        -sha256 \
        | cut -d= -f2 \
        | tr -d ':' \
        | tr '[:upper:]' '[:lower:]')"

    docker build \
        -f "${repo_dir}/infra/nginx/Dockerfile" \
        -t "$nginx_check_image_tag" \
        "$repo_dir"
    echo "Built dynamic edge images and PKI."
    docker network create "$nginx_check_network_name" >/dev/null
    echo "Created isolated dynamic edge network."
    docker run --rm -d \
        --name "$agent_api_probe_container_name" \
        --network "$nginx_check_network_name" \
        --network-alias backend-blue \
        --read-only \
        --cap-drop ALL \
        --security-opt no-new-privileges \
        --tmpfs /tmp:mode=1777,uid=10001,gid=10001 \
        --user 10001:10001 \
        -e "REVOKED_FINGERPRINT_SHA256=${revoked_fingerprint}" \
        -v "${repo_dir}/infra/scripts/agent_api_edge_probe.py:/infra/agent_api_edge_probe.py:ro" \
        "$agent_api_check_image_tag" \
        python /infra/agent_api_edge_probe.py >/dev/null
    echo "Started internal-network backend probe."
    for attempt in 1 2 3 4 5; do
        if docker exec "$agent_api_probe_container_name" \
            python -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8080/ready", timeout=1).close()' \
            >/dev/null 2>&1; then
            break
        fi
        if [ "$attempt" -eq 5 ]; then
            echo "Backend probe did not open its internal TCP listener." >&2
            exit 1
        fi
        sleep 1
    done
    if [ -n "$(docker port "$agent_api_probe_container_name")" ]; then
        echo "Backend probe unexpectedly published its internal TCP port." >&2
        exit 1
    fi

    docker run --rm \
        --network "$nginx_check_network_name" \
        --read-only \
        --cap-drop ALL \
        --security-opt no-new-privileges \
        --tmpfs /tmp:mode=1777,uid=101,gid=101 \
        --user 101:101 \
        --add-host frontend-blue:127.0.0.1 \
        --add-host minio:127.0.0.1 \
        --add-host databasus:127.0.0.1 \
        -e APP_DOMAIN=example.test \
        -e SSL_CERT=/certs/server.crt \
        -e SSL_KEY=/certs/server.key \
        -e ACTIVE_BACKEND_SLOT=backend-blue \
        -e ACTIVE_FRONTEND_SLOT=frontend-blue \
        -e MINIO_PUBLIC_URL=https://s3.example.test \
        -v "${COMPOSE_AGENT_CERTIFICATE_CHAIN_FILE}:/run/secrets/agent_client_ca_certificate:ro" \
        -v "${cert_dir}:/certs:ro" \
        "$nginx_check_image_tag" \
        sh -ec 'mkdir -p /tmp/nginx-conf.d && envsubst "\$APP_DOMAIN \$SSL_CERT \$SSL_KEY \$ACTIVE_BACKEND_SLOT \$ACTIVE_FRONTEND_SLOT \$MINIO_PUBLIC_URL" < /etc/nginx/runtime-templates/site.conf.template > /tmp/nginx-conf.d/site.conf && nginx -t'

    docker run --rm -d \
        --name "$nginx_check_container_name" \
        --network "$nginx_check_network_name" \
        --read-only \
        --cap-drop ALL \
        --security-opt no-new-privileges \
        --tmpfs /tmp:mode=1777,uid=101,gid=101 \
        --user 101:101 \
        --add-host frontend-blue:127.0.0.1 \
        --add-host minio:127.0.0.1 \
        --add-host databasus:127.0.0.1 \
        -e APP_DOMAIN=example.test \
        -e SSL_CERT=/certs/server.crt \
        -e SSL_KEY=/certs/server.key \
        -e ACTIVE_BACKEND_SLOT=backend-blue \
        -e ACTIVE_FRONTEND_SLOT=frontend-blue \
        -e MINIO_PUBLIC_URL=https://s3.example.test \
        -e NGINX_LIVENESS_FAILURE_LIMIT=12 \
        -p "127.0.0.1::18083" \
        -p "127.0.0.1::8443" \
        -v "${COMPOSE_AGENT_CERTIFICATE_CHAIN_FILE}:/run/secrets/agent_client_ca_certificate:ro" \
        -v "${cert_dir}:/certs:ro" \
        "$nginx_check_image_tag" \
        sh -ec 'mkdir -p /tmp/nginx-conf.d && envsubst "\$APP_DOMAIN \$SSL_CERT \$SSL_KEY \$ACTIVE_BACKEND_SLOT \$ACTIVE_FRONTEND_SLOT \$MINIO_PUBLIC_URL" < /etc/nginx/runtime-templates/site.conf.template > /tmp/nginx-conf.d/site.conf && exec nginx -g "daemon off;"' >/dev/null
    private_port="$(docker port "$nginx_check_container_name" 18083/tcp | awk -F: 'NR == 1 {print $NF}')"
    public_port="$(docker port "$nginx_check_container_name" 8443/tcp | awk -F: 'NR == 1 {print $NF}')"

    for attempt in 1 2 3 4 5; do
        if docker exec "$nginx_check_container_name" \
            /usr/local/bin/competency-trainer-nginx-healthcheck >/dev/null 2>&1; then
            break
        fi
        if [ "$attempt" -eq 5 ]; then
            echo "Nginx local liveness probe did not become healthy." >&2
            docker logs "$nginx_check_container_name" >&2
            exit 1
        fi
        sleep 1
    done

    no_certificate_status="$(curl \
        --connect-timeout 3 \
        --max-time 10 \
        -k \
        -sS \
        -o /dev/null \
        -w '%{http_code}' \
        "https://127.0.0.1:${private_port}/internal/agent/v1/matrix/authoring-context" \
        2>/dev/null || true)"
    case "$no_certificate_status" in
        2??)
            echo "Agent API listener accepted a request without a client certificate." >&2
            exit 1
            ;;
    esac
    for certificate_name in wrong-ca-agent expired-agent; do
        rejected_certificate_status="$(agent_request_status \
            "$private_port" \
            "${cert_dir}/${certificate_name}.crt" \
            "${cert_dir}/${certificate_name}.key" \
            GET \
            /internal/agent/v1/matrix/authoring-context 2>/dev/null || true)"
        if [ "$rejected_certificate_status" = "200" ]; then
            echo "nginx accepted the ${certificate_name} certificate." >&2
            exit 1
        fi
    done
    valid_certificate_status="$(agent_request_status \
        "$private_port" \
        "${cert_dir}/valid-agent.crt" \
        "${cert_dir}/valid-agent.key" \
        GET \
        '/internal/agent/v1/matrix/resources?query=NGINX_QUERY_SECRET' 2>/dev/null || true)"
    if [ "$valid_certificate_status" != "200" ]; then
        echo "Valid mTLS client did not reach the backend: HTTP ${valid_certificate_status}." >&2
        docker logs "$nginx_check_container_name" >&2
        docker logs "$agent_api_probe_container_name" >&2
        exit 1
    fi
    rejected_certificate_status="$(agent_request_status \
        "$private_port" \
        "${cert_dir}/revoked-agent.crt" \
        "${cert_dir}/revoked-agent.key" \
        GET \
        /internal/agent/v1/matrix/authoring-context)"
    if [ "$rejected_certificate_status" != "401" ]; then
        echo "Application boundary did not reject the revoked certificate." >&2
        exit 1
    fi
    if [ "$(agent_request_status \
        "$private_port" \
        "${cert_dir}/valid-agent.crt" \
        "${cert_dir}/valid-agent.key" \
        POST \
        /internal/agent/v1/matrix/authoring-context)" != "405" ]; then
        echo "nginx proxied a wrong Agent API method." >&2
        exit 1
    fi
    if [ "$(agent_request_status \
        "$private_port" \
        "${cert_dir}/valid-agent.crt" \
        "${cert_dir}/valid-agent.key" \
        GET \
        /internal/agent/v1/not-allowlisted)" != "404" ]; then
        echo "nginx proxied an unknown Agent API path." >&2
        exit 1
    fi
    public_spoof_status="$(curl \
        --connect-timeout 3 \
        --max-time 10 \
        -k \
        -sS \
        -o /dev/null \
        -w '%{http_code}' \
        -H 'Host: example.test' \
        -H 'X-Agent-Client-Certificate: caller-controlled-value' \
        "https://127.0.0.1:${public_port}/api/healthcheck")"
    if [ "$public_spoof_status" != "204" ]; then
        echo "Public listener did not strip the caller-controlled Agent certificate header." >&2
        exit 1
    fi
    public_internal_status="$(curl \
        --connect-timeout 3 \
        --max-time 10 \
        -k \
        -sS \
        -o /dev/null \
        -w '%{http_code}' \
        -H 'Host: example.test' \
        -H 'X-Agent-Client-Certificate: caller-controlled-value' \
        "https://127.0.0.1:${public_port}/internal/agent/v1/matrix/authoring-context")"
    if [ "$public_internal_status" != "404" ]; then
        echo "Public application hostname exposed the internal Agent contour." >&2
        exit 1
    fi
    public_agent_status="$(curl \
        --connect-timeout 3 \
        --max-time 10 \
        -k \
        -sS \
        -o /dev/null \
        -w '%{http_code}' \
        -H 'Host: agent.example.test' \
        "https://127.0.0.1:${public_port}/internal/agent/v1/matrix/authoring-context")"
    if [ "$public_agent_status" != "404" ]; then
        echo "Public agent hostname did not remain a 404 sink." >&2
        exit 1
    fi

    probe_logs="$(docker exec "$agent_api_probe_container_name" cat /tmp/agent-api-probe.log)"
    if grep -Fq "POST /internal/agent/v1/matrix/authoring-context" <<<"$probe_logs" \
        || grep -Fq "/internal/agent/v1/not-allowlisted" <<<"$probe_logs"; then
        echo "Wrong method or unknown path reached the backend." >&2
        exit 1
    fi
    if ! grep -Fq "GET /api/healthcheck missing 204" <<<"$probe_logs"; then
        echo "Backend probe did not observe a stripped public Agent certificate header." >&2
        exit 1
    fi
    nginx_logs="$(docker logs "$nginx_check_container_name" 2>&1)"
    if ! grep -Fq '"clientVerify":"SUCCESS"' <<<"$nginx_logs"; then
        echo "Missing structured nginx log for a valid certificate." >&2
        exit 1
    fi
    if grep -Fq "NGINX_QUERY_SECRET" <<<"$nginx_logs" \
        || grep -Fq -- "-----BEGIN CERTIFICATE-----" <<<"$nginx_logs"; then
        echo "nginx Agent API logs exposed query or certificate content." >&2
        exit 1
    fi
}

run_nginx_recreate_upgrade_check() {
    local old_compose
    local new_compose
    local old_container_id
    local new_container_id
    local new_mounts

    nginx_recreate_temp_dir="$(mktemp -d)"
    old_compose="${nginx_recreate_temp_dir}/old-compose.yml"
    new_compose="${nginx_recreate_temp_dir}/new-compose.yml"
    printf '%s' "test-client-ca" >"${nginx_recreate_temp_dir}/agent-client-ca.pem"
    cat >"$old_compose" <<EOF
services:
  nginx:
    image: ${nginx_check_image_tag}
    user: "101:101"
    command: ["sleep", "300"]
EOF
    cat >"$new_compose" <<EOF
services:
  nginx:
    image: ${nginx_check_image_tag}
    user: "101:101"
    command: ["sleep", "300"]
    ports:
      - "127.0.0.1::18083"
    secrets:
      - source: agent-client-ca
        target: agent_client_ca_certificate
secrets:
  agent-client-ca:
    file: ${nginx_recreate_temp_dir}/agent-client-ca.pem
EOF
    nginx_recreate_project_name="agent-api-nginx-upgrade-$PPID-$$"
    docker compose \
        -p "$nginx_recreate_project_name" \
        -f "$old_compose" \
        up -d nginx >/dev/null
    old_container_id="$(docker compose \
        -p "$nginx_recreate_project_name" \
        -f "$old_compose" \
        ps -q nginx)"
    docker compose \
        -p "$nginx_recreate_project_name" \
        -f "$new_compose" \
        up -d --force-recreate nginx >/dev/null
    new_container_id="$(docker compose \
        -p "$nginx_recreate_project_name" \
        -f "$new_compose" \
        ps -q nginx)"
    if [ -z "$old_container_id" ] || [ -z "$new_container_id" ] \
        || [ "$old_container_id" = "$new_container_id" ]; then
        echo "Static Agent API rollout did not recreate an already-running nginx container." >&2
        exit 1
    fi
    if [ "$(docker inspect -f '{{.Config.User}}' "$new_container_id")" != "101:101" ]; then
        echo "Recreated nginx did not retain its ordinary non-root UID/GID." >&2
        exit 1
    fi
    if [ "$(docker inspect -f '{{(index (index .HostConfig.PortBindings "18083/tcp") 0).HostIp}}' "$new_container_id")" != "127.0.0.1" ]; then
        echo "Recreated nginx did not receive the private listener binding." >&2
        exit 1
    fi
    new_mounts="$(docker inspect -f '{{range .Mounts}}{{println .Destination}}{{end}}' "$new_container_id")"
    if ! grep -Fxq "/run/secrets/agent_client_ca_certificate" <<<"$new_mounts"; then
        echo "Recreated nginx is missing its Agent client CA secret." >&2
        exit 1
    fi
    if grep -Fxq "/run/agent-api" <<<"$new_mounts"; then
        echo "Recreated nginx retained the removed Agent API socket mount." >&2
        exit 1
    fi
}

run_nginx_recovery_check() {
    local attempt
    local restart_count

    nginx_recovery_container_name="competency-trainer-nginx-recovery-check-$(date +%s)-$$"
    docker run -d \
        --name "$nginx_recovery_container_name" \
        --restart always \
        --read-only \
        --cap-drop ALL \
        --security-opt no-new-privileges \
        --tmpfs /tmp:mode=1777,uid=101,gid=101 \
        --user 101:101 \
        -e NGINX_LIVENESS_FAILURE_LIMIT=2 \
        --entrypoint sh \
        "$nginx_check_image_tag" \
        -c 'trap "exit 0" TERM; while :; do sleep 1; done' >/dev/null

    sleep 11
    if docker exec "$nginx_recovery_container_name" \
        /usr/local/bin/competency-trainer-nginx-healthcheck >/dev/null 2>&1; then
        echo "Nginx recovery probe unexpectedly succeeded without a local nginx listener." >&2
        exit 1
    fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$nginx_recovery_container_name")" != "true" ]; then
        echo "Nginx recovery probe terminated the container before reaching its failure limit." >&2
        exit 1
    fi

    docker exec "$nginx_recovery_container_name" \
        /usr/local/bin/competency-trainer-nginx-healthcheck >/dev/null 2>&1 || true
    for attempt in 1 2 3 4 5; do
        restart_count="$(docker inspect -f '{{.RestartCount}}' "$nginx_recovery_container_name")"
        if [ "$restart_count" -ge 1 ] \
            && [ "$(docker inspect -f '{{.State.Running}}' "$nginx_recovery_container_name")" = "true" ]; then
            docker rm -f "$nginx_recovery_container_name" >/dev/null
            nginx_recovery_container_name=""
            return
        fi
        sleep 1
    done

    echo "Nginx did not restart after the configured liveness failure limit." >&2
    exit 1
}

echo "Checking deployment environment and secret rendering."
run_deploy_env_configuration_check
echo "Checking private listener configuration."
run_private_panel_configuration_check
echo "Checking rendered Compose and nginx invariants."
run_healthcheck_configuration_check
echo "Checking runtime container configuration."
run_runtime_container_security_check
echo "Checking certificate lifecycle configuration."
run_certbot_configuration_check
echo "Checking Agent CA helper."
run_agent_ca_helper_check
echo "Checking MinIO image runtime."
run_minio_image_check
echo "Checking dynamic Agent API edge."
run_nginx_syntax_check
echo "Checking nginx liveness recovery."
run_nginx_recovery_check
echo "Checking nginx static-config recreation."
run_nginx_recreate_upgrade_check
