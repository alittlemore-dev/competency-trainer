#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


AGENT_ACCESS_SECRET_TARGETS = {
    "agent_certificate_chain": "agent_certificate_chain",
    "agent_issuing_certificate": "agent_issuing_certificate",
    "agent_issuing_private_key": "agent_issuing_private_key",
}
AGENT_CODEX_TOOLS = {
    "claim_next_matrix_question",
    "get_matrix_authoring_context",
    "release_matrix_question_claim",
    "save_matrix_question_draft",
    "search_matrix_resources",
}
AGENT_LOCATIONS = {
    "location = /internal/agent/v1/matrix/question-claims {": "POST",
    "location = /internal/agent/v1/matrix/authoring-context {": "GET",
    "location = /internal/agent/v1/matrix/resources {": "GET",
    (
        "location ~ \"^/internal/agent/v1/matrix/question-claims/"
        "[0-9a-f]{32}/draft$\" {"
    ): "PUT",
    (
        "location ~ \"^/internal/agent/v1/matrix/question-claims/"
        "[0-9a-f]{32}$\" {"
    ): "DELETE",
    "location = /internal/agent/v1/certificate-rotations {": "POST",
    (
        "location ~ \"^/internal/agent/v1/certificate-rotations/"
        "[0-9a-f]{32}/confirm$\" {"
    ): "POST",
}


class InvariantError(ValueError):
    pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Check rendered private Agent API infrastructure invariants.",
    )
    parser.add_argument("--compose-json", required=True, type=Path)
    parser.add_argument("--nginx-config", required=True, type=Path)
    parser.add_argument("--codex-config", required=True, type=Path)
    parser.add_argument("--vpn-address", required=True)
    return parser.parse_args()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise InvariantError(message)


def as_list(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


def volume_by_target(service: dict[str, Any], target: str) -> dict[str, Any] | None:
    for volume in as_list(service.get("volumes")):
        if isinstance(volume, dict) and volume.get("target") == target:
            return volume
    return None


def secret_targets(service: dict[str, Any]) -> dict[str, str]:
    result: dict[str, str] = {}
    for secret in as_list(service.get("secrets")):
        if not isinstance(secret, dict):
            continue
        source = secret.get("source")
        target = secret.get("target")
        if isinstance(source, str) and isinstance(target, str):
            result[source] = target
    return result


def published_port(service: dict[str, Any], target: int) -> list[dict[str, Any]]:
    return [
        port
        for port in as_list(service.get("ports"))
        if isinstance(port, dict) and port.get("target") == target
    ]


def check_compose(document: dict[str, Any], vpn_address: str) -> None:
    services = document.get("services")
    require(isinstance(services, dict), "Rendered Compose config has no services object.")
    require("agent-mcp" not in services, "Legacy agent-mcp service remains in Compose.")
    require(
        "agent-db-provision" not in services,
        "Dedicated Agent DB provisioner remains in Compose.",
    )
    nginx = services.get("nginx")
    require("agent-api" not in services, "Separate agent-api service remains in Compose.")
    require(isinstance(nginx, dict), "Rendered Compose config has no nginx service.")

    require(nginx.get("user") == "101:101", "nginx must run with its ordinary UID/GID.")
    require(
        volume_by_target(nginx, "/run/agent-api") is None,
        "nginx must not mount the removed Agent API socket.",
    )
    require(
        secret_targets(nginx) == {"agent_certificate_chain": "agent_client_ca_certificate"},
        "nginx must receive only the public agent client CA chain secret.",
    )
    private_ports = published_port(nginx, 18083)
    require(len(private_ports) == 1, "nginx must publish exactly one Agent API port.")
    require(str(private_ports[0].get("published")) == "18083", "Agent host port must be 18083.")
    require(
        private_ports[0].get("host_ip") == vpn_address,
        "Agent API port must bind only to VPN_BIND_ADDRESS.",
    )

    for service_name, service in services.items():
        if not isinstance(service, dict):
            continue
        if service_name != "nginx":
            require(
                not published_port(service, 18083),
                f"Only nginx may publish target port 18083; found {service_name}.",
            )
        for volume in as_list(service.get("volumes")):
            if not isinstance(volume, dict):
                continue
            source = str(volume.get("source", ""))
            target = str(volume.get("target", ""))
            require(
                "docker.sock" not in source and "docker.sock" not in target,
                f"Docker socket mount found in {service_name}.",
            )
        environment = service.get("environment")
        if isinstance(environment, dict):
            require(
                not any(name.startswith("AGENT_DB_") for name in environment),
                f"Legacy Agent DB environment remains in {service_name}.",
            )
            require(
                not any(name.startswith("AGENT_API_") for name in environment),
                f"Separate Agent API environment remains in {service_name}.",
            )
        require(
            volume_by_target(service, "/run/agent-api") is None,
            f"Removed Agent API socket remains in {service_name}.",
        )

    for backend_name in ("backend-blue", "backend-green"):
        backend = services.get(backend_name)
        require(isinstance(backend, dict), f"Rendered Compose config has no {backend_name} service.")
        require(
            backend.get("ports") in (None, []),
            f"{backend_name} must remain reachable only on the internal Docker network.",
        )
        mounted_secrets = secret_targets(backend)
        require(
            AGENT_ACCESS_SECRET_TARGETS.items() <= mounted_secrets.items(),
            f"{backend_name} must receive the Agent Access issuing material.",
        )

    volumes = document.get("volumes")
    require(isinstance(volumes, dict), "Rendered Compose config has no volumes object.")
    require("agent-api-socket" not in volumes, "Removed agent-api-socket volume remains.")
    secrets = document.get("secrets")
    require(isinstance(secrets, dict), "Rendered Compose config has no secrets object.")
    require("agent_db_password" not in secrets, "Dedicated Agent DB secret remains in Compose.")


def server_blocks(config: str) -> list[str]:
    blocks: list[str] = []
    for match in re.finditer(r"(?m)^\s*server\s*\{", config):
        depth = 0
        for index in range(match.start(), len(config)):
            character = config[index]
            if character == "{":
                depth += 1
            elif character == "}":
                depth -= 1
                if depth == 0:
                    blocks.append(config[match.start() : index + 1])
                    break
    return blocks


def check_nginx(config: str) -> None:
    require("${" not in config, "nginx checker requires fully rendered configuration.")
    require(
        "log_format agent_api_json escape=json" in config,
        "Agent API structured log format is missing.",
    )
    log_format = config.split("log_format agent_api_json escape=json", maxsplit=1)[1].split(";", maxsplit=1)[0]
    for field in (
        '"method":"$request_method"',
        '"uri":"$uri"',
        '"status":$status',
        '"requestId":"$request_id"',
        '"clientVerify":"$ssl_client_verify"',
        '"clientFingerprint":"$ssl_client_fingerprint"',
    ):
        require(field in log_format, f"Agent API log is missing safe field: {field}")
    for forbidden in ("$request_uri", "$ssl_client_escaped_cert", "$request_body"):
        require(forbidden not in log_format, f"Agent API log exposes forbidden data: {forbidden}")
    require(
        "limit_req_zone $ssl_client_fingerprint zone=agent_api_per_certificate:" in config,
        "Agent rate limiting must be keyed by the TLS certificate fingerprint.",
    )
    require("upstream agent_api" not in config, "Removed Agent API upstream remains in nginx.")
    require("/run/agent-api" not in config, "Removed Agent API socket remains in nginx.")
    blocks = server_blocks(config)
    private_blocks = [block for block in blocks if "listen 18083 ssl;" in block]
    require(len(private_blocks) == 1, "nginx must have exactly one private Agent API listener.")
    private = private_blocks[0]
    for directive in (
        "server_name agent.example.test;",
        "ssl_client_certificate /run/secrets/agent_client_ca_certificate;",
        "ssl_verify_client on;",
        "ssl_verify_depth 2;",
        "ssl_protocols TLSv1.2 TLSv1.3;",
        "client_max_body_size 256k;",
        "access_log /dev/stdout agent_api_json;",
        "proxy_set_header X-Request-ID               $request_id;",
        "proxy_set_header X-Agent-Client-Certificate $ssl_client_escaped_cert;",
    ):
        require(directive in private, f"Private Agent API listener is missing: {directive}")
    for location, method in AGENT_LOCATIONS.items():
        require(private.count(location) == 1, f"Expected exact Agent API route once: {location}")
        require(
            f"if ($request_method != {method}) {{ return 405; }}" in private,
            f"Agent API route is missing its {method} method allowlist.",
        )
    require(private.count("proxy_pass http://backend;") == 7, "Only seven Agent API routes may proxy.")
    require(private.count("limit_req zone=agent_api_per_certificate") == 7, "All routes need rate limits.")
    require("location / {\n        return 404;" in private, "Unknown private routes must return 404.")

    public_tls = [
        block
        for block in blocks
        if "listen 8443 ssl;" in block and "server_name agent.example.test;" in block
    ]
    require(len(public_tls) == 1, "Public TLS must have one explicit agent hostname sink.")
    require("return 404;" in public_tls[0], "Public agent hostname must return 404.")
    require("proxy_pass" not in public_tls[0], "Public agent hostname must never proxy.")
    require("ssl_verify_client" not in public_tls[0], "Public 443 must not expose Agent API mTLS.")
    public_http = [
        block
        for block in blocks
        if "listen 8080;" in block and "server_name agent.example.test;" in block
    ]
    require(len(public_http) == 1, "Public HTTP must have one agent ACME sink.")
    require("/.well-known/acme-challenge/" in public_http[0], "Agent hostname must support ACME.")
    require("return 404;" in public_http[0], "Non-ACME agent HTTP requests must return 404.")
    require("proxy_pass" not in public_http[0], "Public agent HTTP hostname must never proxy.")

    public_main = [
        block
        for block in blocks
        if "listen 8443 ssl;" in block and "server_name example.test;" in block
    ]
    require(len(public_main) == 1, "Public TLS must have one main application listener.")
    require(
        'proxy_set_header X-Agent-Client-Certificate "";' in public_main[0],
        "Public application listener must strip caller-controlled Agent certificates.",
    )
    require(
        "location ^~ /internal/agent/v1" in public_main[0]
        and "return 404;" in public_main[0].split(
            "location ^~ /internal/agent/v1",
            maxsplit=1,
        )[1].split("}", maxsplit=1)[0],
        "Public application listener must reject the internal Agent contour.",
    )


def toml_section(config: str, section_name: str) -> str:
    marker = f"[{section_name}]"
    require(marker in config, f"Codex config has no {section_name} section.")
    return config.split(marker, maxsplit=1)[1].split("\n[", maxsplit=1)[0]


def toml_string_values(section: str, field_name: str) -> list[str]:
    match = re.search(rf"(?ms)^{re.escape(field_name)}\s*=\s*\[(.*?)^\]", section)
    require(match is not None, f"Codex config has no {field_name} list.")
    return re.findall(r'"([^"]+)"', match.group(1))


def check_codex_config(config: str) -> None:
    server = toml_section(config, "mcp_servers.competency_trainer_matrix")
    require('command = "bash"' in server, "Codex bridge must use the audited local launcher.")
    require(
        'args = ["infra/scripts/agent_bridge.sh"]' in server,
        "Codex must start only the constrained local stdio bridge.",
    )
    require("env_vars" not in server, "Codex bridge must read only its dedicated local env file.")
    require(
        set(toml_string_values(server, "enabled_tools")) == AGENT_CODEX_TOOLS,
        "Codex enabled_tools must contain exactly the five authoring tools.",
    )
    require('default_tools_approval_mode = "prompt"' in server, "Unknown tools must prompt.")
    require(
        "[mcp_servers.competency_trainer_matrix.env]" not in config,
        "Codex bridge environment must be owned by the audited local launcher.",
    )
    configured_tools = set(
        re.findall(r"(?m)^\[mcp_servers\.competency_trainer_matrix\.tools\.([a-z_]+)\]$", config),
    )
    require(configured_tools == AGENT_CODEX_TOOLS, "Per-tool approvals exceed the allowlist.")
    for tool_name in AGENT_CODEX_TOOLS:
        tool = toml_section(config, f"mcp_servers.competency_trainer_matrix.tools.{tool_name}")
        require(
            tool.strip() == 'approval_mode = "approve"',
            f"Codex tool {tool_name} must be explicitly approved.",
        )


def main() -> int:
    args = parse_args()
    try:
        compose_document = json.loads(args.compose_json.read_text(encoding="utf-8"))
        require(isinstance(compose_document, dict), "Rendered Compose config must be an object.")
        check_compose(compose_document, args.vpn_address)
        check_nginx(args.nginx_config.read_text(encoding="utf-8"))
        check_codex_config(args.codex_config.read_text(encoding="utf-8"))
    except (InvariantError, OSError, json.JSONDecodeError) as exc:
        print(f"check_agent_api_invariants.py: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
