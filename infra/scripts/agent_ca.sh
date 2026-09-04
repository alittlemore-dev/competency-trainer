#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "${script_dir}/../.." && pwd)"

require_command() {
    local command_name="$1"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "${command_name} could not be found. Install it." >&2
        exit 1
    fi
}

require_external_absolute_directory() {
    local path="$1"
    local description="$2"

    if [[ "$path" != /* ]]; then
        echo "${description} must be an absolute path outside the repository." >&2
        exit 1
    fi
    case "$path" in
        "$repo_dir" | "$repo_dir"/*)
            echo "${description} must stay outside the repository: ${path}" >&2
            exit 1
            ;;
    esac
}

require_absent_file() {
    local path="$1"

    if [ -e "$path" ]; then
        echo "Refusing to overwrite existing PKI material: ${path}" >&2
        exit 1
    fi
}

initialize_ca() {
    local offline_root_dir="${1:?offline root directory is required}"
    local issuing_dir="${2:?issuing directory is required}"
    local root_key="${offline_root_dir}/agent-root-ca.key.pem"
    local root_certificate="${offline_root_dir}/agent-root-ca.cert.pem"
    local issuing_key="${issuing_dir}/agent-issuing-ca.key.pem"
    local issuing_request="${issuing_dir}/agent-issuing-ca.csr.pem"
    local issuing_certificate="${issuing_dir}/agent-issuing-ca.cert.pem"
    local certificate_chain="${issuing_dir}/agent-certificate-chain.pem"
    local extension_file

    require_external_absolute_directory "$offline_root_dir" "Offline root directory"
    require_external_absolute_directory "$issuing_dir" "Issuing directory"
    for path in \
        "$root_key" \
        "$root_certificate" \
        "$issuing_key" \
        "$issuing_request" \
        "$issuing_certificate" \
        "$certificate_chain"; do
        require_absent_file "$path"
    done

    mkdir -p "$offline_root_dir" "$issuing_dir"
    chmod 700 "$offline_root_dir" "$issuing_dir"
    extension_file="$(mktemp)"
    trap 'rm -f "$extension_file"' RETURN

    openssl genpkey \
        -algorithm EC \
        -pkeyopt ec_paramgen_curve:P-256 \
        -pkeyopt ec_param_enc:named_curve \
        -out "$root_key"
    chmod 600 "$root_key"
    openssl req \
        -x509 \
        -new \
        -sha256 \
        -key "$root_key" \
        -days 3650 \
        -subj "/CN=Competency Trainer Agent Offline Root CA" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:1" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -out "$root_certificate"

    openssl genpkey \
        -algorithm EC \
        -pkeyopt ec_paramgen_curve:P-256 \
        -pkeyopt ec_param_enc:named_curve \
        -out "$issuing_key"
    chmod 600 "$issuing_key"
    openssl req \
        -new \
        -sha256 \
        -key "$issuing_key" \
        -subj "/CN=Competency Trainer Agent Production Issuing CA" \
        -out "$issuing_request"
    printf '%s\n' \
        "basicConstraints=critical,CA:TRUE,pathlen:0" \
        "keyUsage=critical,keyCertSign,cRLSign" \
        "subjectKeyIdentifier=hash" \
        "authorityKeyIdentifier=keyid,issuer" >"$extension_file"
    openssl x509 \
        -req \
        -sha256 \
        -in "$issuing_request" \
        -CA "$root_certificate" \
        -CAkey "$root_key" \
        -CAcreateserial \
        -days 1825 \
        -extfile "$extension_file" \
        -out "$issuing_certificate"
    chmod 644 "$root_certificate" "$issuing_request" "$issuing_certificate"
    {
        sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' "$issuing_certificate"
        sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' "$root_certificate"
    } >"$certificate_chain"
    chmod 644 "$certificate_chain"

    openssl verify -CAfile "$root_certificate" "$issuing_certificate"
    echo "Offline root created in ${offline_root_dir}; keep it offline and never deploy its private key."
    echo "Issuing certificate, private key, and chain created in ${issuing_dir}."
}

create_client_csr() {
    local agent_id="${1:?agent ID is required}"
    local output_dir="${2:?client output directory is required}"
    local client_key
    local client_request

    if [[ ! "$agent_id" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
        echo "Agent ID must contain only letters, digits, dot, underscore, or hyphen (1-64 characters)." >&2
        exit 1
    fi
    require_external_absolute_directory "$output_dir" "Client output directory"
    client_key="${output_dir}/${agent_id}.key.pem"
    client_request="${output_dir}/${agent_id}.csr.pem"
    require_absent_file "$client_key"
    require_absent_file "$client_request"

    mkdir -p "$output_dir"
    chmod 700 "$output_dir"
    openssl genpkey \
        -algorithm EC \
        -pkeyopt ec_paramgen_curve:P-256 \
        -pkeyopt ec_param_enc:named_curve \
        -out "$client_key"
    chmod 600 "$client_key"
    openssl req \
        -new \
        -sha256 \
        -key "$client_key" \
        -subj "/CN=${agent_id}" \
        -out "$client_request"
    chmod 644 "$client_request"

    echo "Client private key created at ${client_key}; it must remain only on the client."
    echo "Submit ${client_request} through the owner-only agent registration flow."
}

require_command openssl
umask 077

action="${1:?action is required}"
shift

case "$action" in
    init)
        initialize_ca "$@"
        ;;
    client-csr)
        create_client_csr "$@"
        ;;
    *)
        echo "Usage: $0 init OFFLINE_ROOT_DIR ISSUING_DIR" >&2
        echo "       $0 client-csr AGENT_ID CLIENT_OUTPUT_DIR" >&2
        exit 2
        ;;
esac
