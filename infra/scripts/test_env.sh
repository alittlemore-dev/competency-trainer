#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "${script_dir}/../.." && pwd)"
cd "$repo_dir"

action="${1:?action is required}"
test_env_file="${TEST_ENV_FILE:-.env.test}"
test_compose_file="${TEST_COMPOSE_FILE:-docker-compose.test.yml}"
test_compose_project_name="${TEST_COMPOSE_PROJECT_NAME:-competency-trainer-test}"

case "$action" in
    up)
        docker compose \
            --project-name "$test_compose_project_name" \
            --env-file "$test_env_file" \
            -f "$test_compose_file" \
            up -d --wait postgres-test
        ;;
    down)
        docker compose \
            --project-name "$test_compose_project_name" \
            --env-file "$test_env_file" \
            -f "$test_compose_file" \
            down -v --remove-orphans
        ;;
    *)
        echo "Unknown test environment action: $action" >&2
        exit 2
        ;;
esac
