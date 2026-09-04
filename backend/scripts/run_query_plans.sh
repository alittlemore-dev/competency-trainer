#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$script_dir/common.sh"
cd "$backend_dir"

profile="${1:?profile is required}"
env_file="${2:?env file path is required}"

if [ ! -f "$env_file" ]; then
    echo "Environment file does not exist: $env_file" >&2
    exit 2
fi

ensure_backend_deps
TEST_ENV_FILE="$env_file"
if [ "$profile" = "stress" ] && [ "${QUERY_PLANS_REUSE_AVAILABLE_DB:-false}" != "true" ]; then
    TEST_DB_COMPOSE_PROJECT_NAME="competency-trainer-query-plans-stress"
    stress_db_port="${QUERY_PLANS_STRESS_DB_PORT:-55433}"
    ensure_backend_test_db "docker-compose.query-plans-stress.yml" "$stress_db_port"
else
    ensure_backend_test_db
fi
trap cleanup_owned_test_db EXIT

require_var() {
    name="$1"
    if [ -z "${!name:-}" ]; then
        echo "$name is required. Set it in $env_file or pass it in the environment." >&2
        exit 2
    fi
}

require_var PERFORMANCE_REPORT_DIR
report_run_dir="$(create_performance_report_run_dir "$PERFORMANCE_REPORT_DIR" "query-plans")"

PYTHONPATH=src uv run --locked --all-groups python -m performance.query_plans \
    --profile "$profile" \
    --report-dir "$report_run_dir" \
    --fail-on-finding
