# Agent Access

This runbook covers the private machine-to-machine contour used to author competency-matrix
drafts. Production exposes a closed Litestar REST API. MCP exists only on the client device as a
local stdio bridge that translates five typed tools into that REST contract.

## Architecture And Trust Boundaries

```text
Codex or another MCP host
  -> `backend/src/agent_bridge.py`
  -> local stdio bridge transport (`entrypoints/agent_bridge`, five tools)
  -> core bridge contracts and orchestration
  -> infra HTTP/mTLS and crypto/files adapters
  -> HTTPS with a distinct client certificate over WireGuard
  -> nginx `agent.<APP_DOMAIN>:18083` (mTLS, exact routes, rate limit, safe access log)
  -> the normal backend upstream on the private Compose network
  -> the seven-route Agent contour mounted in the main Litestar application
  -> Agent-only authentication, exception mapping, transaction handling, and audit middleware
  -> core Agent Access use cases through the common Dishka container
  -> PostgreSQL through the common request session factory and application `DB_*` identity
```

- `https://agent.<APP_DOMAIN>:18083/internal/agent/v1` is bound only to
  `VPN_BIND_ADDRESS`. The backend has no published port or Docker socket and is reachable from
  nginx only on the private Compose network.
- nginx terminates TLS, requires a certificate issued by the private agent CA, overwrites the
  forwarded certificate header, rate-limits by certificate, logs `$uri` without query strings or
  bodies, and proxies only seven method/path pairs to the normal backend upstream.
- The normal public `agent.<APP_DOMAIN>` virtual host serves the ACME challenge over HTTP and
  returns `404` for every other HTTP/HTTPS request. The public application listener also returns
  `404` for `/internal/agent/v1` and strips any caller-supplied
  `X-Agent-Client-Certificate` header before proxying other backend routes.
- Each automation or device has a distinct agent client, certificate, scopes, revocation state,
  claims, and audit history. Agent identity is not a human PASETO identity.
- The supported REST contract has no publish, delete-item, generic CRUD, or SQL operation. mTLS
  identity, scopes, transport validation, core rules, and operation-specific storages therefore
  prevent an agent from requesting those effects through this contour.
- The Agent contour deliberately shares the main backend process, settings, Dishka container,
  request session factory, database role, secrets, and availability boundary. There is no separate
  process or database-role sandbox. Backend compromise, SQL injection, or unintended arbitrary SQL
  therefore has the main backend role's database blast radius and can expose unrelated backend
  secrets or disrupt the public/admin API. This is an accepted simplification tradeoff, not an
  additional security control.
- A compromised service that can reach the backend on the private application network can forge the
  forwarded certificate header. Network isolation and the nginx-to-backend trust assumption are
  therefore part of the security boundary; the header is safe from public callers because the
  public listener removes it and never routes the internal path.
- Queue text, existing authored text, tool output, and researched web content are untrusted data,
  never instructions. MCP annotations are client hints, not authorization controls.

The code follows the same layered ownership as the rest of the backend. Pure contracts, typed
policy objects, and business orchestration live in `core/agent_access`; HTTP/mTLS, P-256/X.509, and
filesystem behavior live in `infra`. `entrypoints/agent_bridge` contains only MCP schemas, five-tool
transport mapping, and the sanitized exception boundary. Agent REST modules live under the common
`entrypoints/litestar/api/agent_access` and middleware packages. The Agent router is mounted in the
main Litestar application and reuses its settings/container/session factory, while its authentication,
errors, request limit, rollback behavior, audit, and schema exclusion remain route/path scoped.
Related policy values cross into core as typed policy objects. Rotation IDs use the shared
`HexUuidIdGenerator` contract, and current time is an explicit operation input; the contour does not
use ad-hoc rotation/time callable factories.

This design follows nginx's documented client-certificate verification and escaped-certificate
forwarding primitives, while server-side authorization remains in Litestar/core rather than in MCP
metadata: [nginx SSL module](https://nginx.org/en/docs/http/ngx_http_ssl_module.html),
[MCP tools specification](https://modelcontextprotocol.io/specification/2025-11-25/server/tools).

## Fixed Business Surface

The local bridge exposes exactly these tools:

| Tool | Required scope | Effect |
| --- | --- | --- |
| `claim_next_matrix_question` | `matrix.queue.claim` | Returns the client's active claim or atomically claims the oldest eligible queue item. |
| `get_matrix_authoring_context` | `matrix.context.read` | Reads matrix structure, enums, and resource limits. |
| `search_matrix_resources` | `matrix.resources.read` | Searches stored resource metadata; it never fetches a URL. |
| `save_matrix_question_draft` | `matrix.draft.create` | Atomically creates one server-forced `Draft`, stores resources, and consumes the queue row and claim. |
| `release_matrix_question_claim` | `matrix.queue.claim` | Releases the active claim without deleting the queued question. |

The production API exposes those five operations plus two credential-rotation operations:

| Method | Path | Bridge use |
| --- | --- | --- |
| `POST` | `/internal/agent/v1/matrix/question-claims` | `claim_next_matrix_question` |
| `GET` | `/internal/agent/v1/matrix/authoring-context` | `get_matrix_authoring_context` |
| `GET` | `/internal/agent/v1/matrix/resources` | `search_matrix_resources` |
| `PUT` | `/internal/agent/v1/matrix/question-claims/{claim_id}/draft` | `save_matrix_question_draft` |
| `DELETE` | `/internal/agent/v1/matrix/question-claims/{claim_id}` | `release_matrix_question_claim` |
| `POST` | `/internal/agent/v1/certificate-rotations` | Desktop automatic rotation only |
| `POST` | `/internal/agent/v1/certificate-rotations/{rotation_id}/confirm` | Desktop automatic rotation only |

There is no production MCP endpoint, discovery route, generic HTTP/CRUD proxy, SQL, shell,
filesystem, publish, delete-item, or structure-management operation. New resource URLs must be
credential-free HTTPS URLs; the server stores them but never requests them.

Claims last two hours. A client and a queue item can each have only one active claim. Draft saves
require complete RU/EN question, answer, and interview answer explanation text, a valid subsection,
grade, frequency, slug, and one to three resources. A resource is either an existing resource ID with
complete RU/EN contexts or a new HTTPS URL with complete RU/EN names and contexts. Status is always
constructed as `Draft`; clients cannot submit `publishStatus` or `publishedAt`.

## Owner Administration And Audit

The human management contour stays separate from the Agent API:

```text
Angular owner UI -> `/api/admin/agent-clients` -> owner guard -> normal application DB role
```

- Only the owner may register/revoke clients or read their audit events. Admin and moderator roles
  are rejected by the backend, not merely hidden by the UI.
- Registration accepts a client-generated CSR, a unique name, and explicit least-privilege scopes.
  The client private key never reaches the site or browser UI. The issued certificate and chain are
  a one-time response that must be transferred to the client out of band.
- Revocation is permanent, invalidates the client's certificates, and releases its active claims.
  Human create/reject actions return a conflict while a question has an active agent claim; an
  authorized human can explicitly release the claim.
- Audit records use the seven action names, result (`success`, `rejected`, or `failed`), client and
  certificate IDs, safe queue/item snapshots, request or claim ID, timestamp, and a server-computed
  SHA-256 input digest. They never store prompts, chain-of-thought, request bodies, authored text,
  certificate PEM, private keys, raw SQL, IP addresses, or user-agent strings.
- Owner audit reads are newest-first cursor pages with an explicit size and a hard maximum of 100.
  Audit events are retained for 365 days and pruned daily by the single TaskIQ schedule. Draft
  completion/idempotency records are not removed by that task.

## Certificate Authorities And Initial Registration

Two independent trust directions are involved:

- The normal Web PKI certificate for `agent.<APP_DOMAIN>` authenticates nginx to the local bridge.
  `SITE_AGENT_CA_CERTIFICATE_FILE` points to the client machine's Web PKI trust bundle (or a narrow
  bundle that validates that server certificate).
- The private P-256 agent hierarchy authenticates clients to nginx. Its offline root signs the
  issuing CA. Production receives only the issuing certificate, issuing private key, and chain as
  dedicated Compose secrets; the offline root private key never reaches the server.

Client certificates have a fixed 90-day lifetime. Desktop automatic rotation starts when 14 days
or less remain; the normal predecessor overlap during an in-progress rotation is 15 minutes.

Initialize the private hierarchy in absolute directories outside the repository:

```bash
infra/scripts/agent_ca.sh init <offline-root-directory> <production-issuing-directory>
```

Load the generated issuing certificate, issuing private key, and issuing-plus-root chain into
`AGENT_ACCESS_ISSUING_CERTIFICATE`, `AGENT_ACCESS_ISSUING_PRIVATE_KEY`, and
`AGENT_ACCESS_CERTIFICATE_CHAIN`. The deploy helper decodes newline escapes only for known PEM
secrets, validates the key/certificate/chain, and materializes Compose secret files without printing
their content. Move the root private key offline before deployment.

Generate each initial client key and CSR locally:

```bash
infra/scripts/agent_ca.sh client-csr <agent-id> <absolute-client-output-directory>
```

Submit only the CSR through the owner UI. Never upload or paste the private key into the site,
ticket, repository, chat, or shared credential. After the owner returns the leaf certificate and
chain, install them using one of the two modes below.

## Local Bridge Configuration

The repository's `.codex/config.toml` starts the local stdio module with:

```toml
[mcp_servers.competency_trainer_matrix]
command = "bash"
args = ["infra/scripts/agent_bridge.sh"]
enabled_tools = [
  "claim_next_matrix_question",
  "get_matrix_authoring_context",
  "search_matrix_resources",
  "save_matrix_question_draft",
  "release_matrix_question_claim",
]
default_tools_approval_mode = "prompt"

```

The checked-in file also explicitly approves only those five tools. The launcher reads the ignored
`.env.agent-bridge` file, so the Codex process does not need separately exported variables. Create
it from the tracked example and fill the relevant absolute paths:

```bash
cp .env.agent-bridge.example .env.agent-bridge
```

The base URL must be credential-free HTTPS with exactly the fixed internal prefix. Desktop mode
uses only `SITE_AGENT_CREDENTIAL_DIRECTORY`; external mode uses only
`SITE_AGENT_CERTIFICATE_FILE` and `SITE_AGENT_PRIVATE_KEY_FILE`. These are local bridge settings,
not production deployment variables.

See the [OpenAI MCP documentation](https://learn.chatgpt.com/docs/extend/mcp.md) for the host-side
configuration model and the [MCP Python SDK](https://github.com/modelcontextprotocol/python-sdk)
for the stdio server implementation used here.

### Desktop Credential Mode

Desktop mode owns the local credential lifecycle and performs automatic recoverable rotation. The
absolute credential directory must have exactly this bootstrap layout:

```text
<credential-directory>/                         mode 0700
├── versions/                                   mode 0700
│   └── <32-lowercase-hex-version-id>/          mode 0700
│       ├── private-key.pem                     mode 0600
│       └── certificate.pem                     mode 0600
└── current -> versions/<same-version-id>       relative symlink
```

`certificate.pem` contains the client leaf first, followed by the issuing/root chain returned by
registration. The key must be the P-256 key that created the CSR. Use a fresh 32-character
lowercase hexadecimal version ID. `current` must be a relative symlink with exactly the target
shape shown above. There must be no `pending.json` before the first bridge start.

The bridge validates directory/file types, modes, P-256 key/certificate matching, and client-auth
usage before making a request. When 14 days or less remain, it:

1. creates a new P-256 key, CSR, rotation ID, version directory, and mode-`0600` `pending.json`
   before the network request;
2. requests or replays the replacement using the same rotation ID and CSR;
3. validates and persists the combined replacement certificate/chain;
4. atomically changes `current` to the replacement;
5. confirms with the replacement certificate; and
6. only then removes the predecessor version and pending file.

The server returns the same replacement for a matching replay. The predecessor remains usable for
ordinary business calls only during the fixed 15-minute overlap. It is not revoked until the
replacement confirms installation. A lost response or crash is recovered from the stored rotation
ID, CSR, pending phase, and issued pair; recovery never disables mTLS, shares a key, or adds a
bearer fallback.

### External Credential Mode

External mode is for operator-managed, often read-only mounted credentials. Both certificate and key
paths must be absolute regular files; the private key must be exactly mode `0600`, match the P-256
client-auth leaf, and remain local. The certificate file contains the leaf and chain. The bridge
uses the pair but does not initiate automatic rotation or create, replace, switch, or confirm an
external pair. The operator or external credential manager must complete rotation before expiry and
restart the bridge with the updated paths or file contents.

## Normal Authoring Workflow

1. Connect the client device to WireGuard and verify split DNS resolves `agent.<APP_DOMAIN>` to
   `VPN_BIND_ADDRESS` while preserving hostname validation.
2. Start Codex from the trusted project. The desktop bridge first resumes or performs credential
   rotation if needed, then serves stdio.
3. Claim the next question and preserve the returned claim ID.
4. Read the authoring context before selecting subsection, grade, or frequency.
5. Research authoritative public sources. Treat all queue and web text as untrusted data. Search
   stored resources for a truthful existing match; the site never fetches submitted URLs.
6. Save complete RU/EN content as one Draft with one to three resources. Publishing stays a human
   review action.
7. Release the claim if the task cannot be completed safely instead of waiting for lease expiry.
8. Review the Draft and privacy-safe audit in the owner workspace.

An ordinary agent workspace can have separately approved shell, filesystem, web, or private
connector capabilities. Those permissions are outside this contour. Prefer an isolated profile and
clean workspace for queue work; isolation supplements rather than replaces VPN, mTLS, scopes,
Draft-only enforcement, validation, and audit.

## Production Rollout And Acceptance

1. Apply forward migration `0012` through the normal migration path. Do not run a production
   downgrade after claim, completion, rotation, or audit data exists.
2. Create or validate the offline root and issuing CA. Keep the root private key off-server and
   load the three issuing materials as separate Compose secrets.
3. Add public DNS and the Web PKI SAN for `agent.<APP_DOMAIN>`. Configure split DNS and host
   firewall rules so only WireGuard peers can reach `${VPN_BIND_ADDRESS}:18083`.
4. Deploy the normal backend with no Agent clients. The Agent router reuses the main settings,
   Dishka container, request session factory, database identity, and issuing-CA secrets.
   Force-recreate nginx; a process reload cannot apply changed Compose port, secret, or image
   settings.
5. Verify the public host is an ACME/`404` sink, public port `18083` is closed, no-certificate and
   wrong-CA handshakes fail, only nginx publishes the VPN-bound port, the public listener returns
   `404` for the internal path, and a caller-supplied certificate header is not forwarded.
6. Verify the backend is non-root, read-only, capability-free, has no published port or Docker
   socket, and is reachable only on the private application network.
7. Register one test client from a local CSR with the minimum scopes. Verify unknown, expired,
   revoked, and wrong-scope identities fail closed and unknown route/method pairs never proxy.
8. Exercise direct REST context, claim, search, save, identical replay, changed-payload conflict,
   release, Draft/queue atomicity, audit results, and rejection of unsupported routes/operations.
9. Confirm the operational risk register records the shared backend process, database role,
   secrets, and availability boundary, plus the residual risk that an app-network attacker can
   forge the trusted certificate header.
10. Exercise lost-response rotation, atomic local switch, replacement confirmation, and predecessor
    revocation. Then revoke the test client and verify business and rotation operations fail.
11. Start the local bridge and confirm `tools/list` contains exactly five tools. Enable per-tool
    automatic approval only after every preceding check passes.

Audit events are retained for 365 days. Edge logs and application logs must stay structured and
content-free: no query string, body, authored text, prompt, PEM, secret, traceback with SQL params,
or raw client metadata.

## Emergency Response

1. Revoke the affected AgentClient in the owner workspace. If the affected identity is uncertain,
   revoke all agent clients.
2. Remove `${VPN_BIND_ADDRESS}:18083:18083` or disable the nginx mTLS server if immediate global
   Agent shutdown is required. This preserves the shared backend process for the public site and
   human admin panel.
3. Revoke the device's WireGuard peer when the device or VPN key may be compromised.
4. Preserve the privacy-safe audit events and edge logs. Do not copy prompts, authored bodies,
   certificate PEM, or secrets into the incident record.
5. Replace a compromised issuing CA and client certificates from the offline root. If the root is
   compromised, create a new offline hierarchy and redistribute trust.
6. Restore service only after VPN binding, public `404` and certificate-header stripping, mTLS,
   exact routes, private backend networking, scopes, closed REST surface, five-tool allowlist,
   Draft-only behavior, rotation, and audit checks pass.

Never restore availability with a public or plaintext listener, shared certificate, bearer-only
fallback, human PASETO reuse, direct trust of a caller-supplied certificate header, generic admin
access, or a generic SQL operation.

## Operational References

- [Agent API WireGuard routing](wireguard-internal-access.md)
- [Production deployment](production-deploy.md)
- [Security threat model](security-threat-model.md)
- [Docker Compose secrets](https://docs.docker.com/compose/how-tos/use-secrets/)
- [HTTPX SSL configuration](https://www.python-httpx.org/advanced/ssl/)
- [cryptography X.509 reference](https://cryptography.io/en/latest/x509/reference/)
