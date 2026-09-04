#!/usr/bin/env bash

test_services_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
test_services_repo_dir="$(cd -- "${test_services_script_dir}/../.." && pwd)"

TEST_DB_OWNED="${TEST_DB_OWNED:-0}"
TEST_DB_ENV_FILE=""
TEST_DB_COMPOSE_FILE=""
TEST_DB_COMPOSE_PROJECT_NAME="${TEST_DB_COMPOSE_PROJECT_NAME:-competency-trainer-test}"

resolve_path_from() {
    local base_dir="$1"
    local path="$2"
    local path_dir
    local path_base

    if [[ "$path" = /* ]]; then
        printf '%s\n' "$path"
        return
    fi

    path_dir="$(dirname -- "$path")"
    path_base="$(basename -- "$path")"
    printf '%s/%s\n' "$(cd -- "${base_dir}/${path_dir}" && pwd -P)" "$path_base"
}

normalize_multiline_env_var() {
    local name="$1"
    local value="${!name:-}"

    if [ -n "$value" ]; then
        printf -v "$name" '%b' "$value"
        export "$name"
    fi
}

load_env_file() {
    local env_file="$1"

    if [ -f "$env_file" ]; then
        set -a
        # shellcheck disable=SC1090
        . "$env_file"
        set +a
    fi

    normalize_multiline_env_var AUTH_PUBLIC_KEY
    normalize_multiline_env_var AUTH_PRIVATE_KEY
}

tcp_port_open() {
    local host="$1"
    local port="$2"

    (echo >"/dev/tcp/${host}/${port}") >/dev/null 2>&1
}

test_db_is_available() {
    local host="${DB_HOST:-localhost}"
    local port="${DB_PORT:-55432}"

    tcp_port_open "$host" "$port"
}

ensure_test_db() {
    local env_file="$1"
    local compose_file="${2:-docker-compose.test.yml}"
    local forced_port="${3:-}"

    TEST_DB_ENV_FILE="$(resolve_path_from "$PWD" "$env_file")"
    TEST_DB_COMPOSE_FILE="$(resolve_path_from "$test_services_repo_dir" "$compose_file")"

    load_env_file "$TEST_DB_ENV_FILE"
    if [ -n "$forced_port" ]; then
        DB_PORT="$forced_port"
        export DB_PORT
    fi

    if test_db_is_available; then
        TEST_DB_OWNED=0
        return
    fi

    (
        cd "$test_services_repo_dir"
        docker compose \
            --project-name "$TEST_DB_COMPOSE_PROJECT_NAME" \
            --env-file "$TEST_DB_ENV_FILE" \
            -f "$TEST_DB_COMPOSE_FILE" \
            up -d --wait postgres-test
    )
    TEST_DB_OWNED=1
}

cleanup_owned_test_db() {
    if [ "${TEST_DB_OWNED:-0}" != "1" ]; then
        return
    fi

    (
        cd "$test_services_repo_dir"
        docker compose \
            --project-name "$TEST_DB_COMPOSE_PROJECT_NAME" \
            --env-file "$TEST_DB_ENV_FILE" \
            -f "$TEST_DB_COMPOSE_FILE" \
            down -v --remove-orphans
    ) || true
    TEST_DB_OWNED=0
}
