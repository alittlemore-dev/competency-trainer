# Production Deploy

Production deploy is a manual server-build deploy:

1. The root CI workflow is an orchestration graph: each job delegates its implementation to a
   private reusable workflow under `.github/workflows/_*.yaml`.
2. Pushes that change only files under `docs/**`, `.github/badges/**`, `.github/README.md`,
   and/or `.github/README_RU.md` are ignored by the root CI workflow.
3. GitHub Actions runs backend and frontend quality gates in parallel.
4. Backend tests wait only for backend gates, while frontend tests wait only for frontend gates.
5. The blocking `realistic` query-plan regression gate runs after backend tests. Public API
   full-stack smoke coverage is part of the backend integration suite. The larger `stress`
   query-plan profile is available only from the dedicated manual workflow and reports latency as
   an observation while keeping plan-shape checks strict.
6. Frontend SSR smoke and Lighthouse CI run as separate jobs after frontend tests.
7. Dockerfile lint, Trivy config scan, per-image Docker build/image scans, and infrastructure
   security checks run in parallel after the smoke gates.
8. Deploy is a separate **Deploy to production** workflow triggered only by
   `workflow_dispatch`.
9. The deploy workflow has no CI `needs` graph and does not run tests, linters, smoke checks,
   Docker/image scans, or infrastructure security checks.
10. The deploy workflow calls the private reusable `.github/workflows/_deploy.yaml` workflow.
11. The deploy job targets the protected `production` environment, so GitHub waits for the
   **Review deployments** / **Approve and deploy** action before running deploy steps.
12. The deploy job renders a runtime `.env` from `infra/deploy/runtime-env.manifest.json`.
13. GitHub Actions syncs source/config to the server.
14. When the `issue_certificates` input is selected, the server runs `make certbot-issue` before
    deployment startup.
15. The server runs `make run`, which builds images locally and switches the healthy blue/green
    slot.

The post-smoke container security jobs use the same Make targets in CI and locally:

```bash
make security-trivy-config
make security-backend-docker-image IMAGE_TAG=local-security-check
make security-frontend-docker-image IMAGE_TAG=local-security-check
make security-nginx-docker-image IMAGE_TAG=local-security-check
```

Each image target builds from the current checkout, runs Dockle and Trivy, and removes only the
temporary image tag it created. Use an image tag that does not already exist locally.

Locally built runtime images use the GitHub commit SHA from the required `IMAGE_TAG` runtime
environment entry. `docker-compose.yml` intentionally has no `latest` fallback for the backend,
frontend, nginx, or MinIO wrapper images, so a production start fails early if the deploy renderer
does not provide the tag.

Start deploy from **Actions** -> **Deploy to production** -> **Run workflow** on `main`. Select
`issue_certificates` when the certificate must be issued again, including after adding a hostname
to the certificate SAN list. The repository environment must restrict production deployments to
`main` and require reviewer approval. Without those GitHub Environment protection rules, the
workflow remains manual, but production deploys would no longer have the environment approval and
branch protections described here.

## GitHub Environment

Create a GitHub Environment named `production`.

Required protection rules:

- Required reviewers are enabled, so the deploy job waits for **Approve and deploy**.
- Deployment branches are restricted to `main`.

Deploy connection variables:

- `REMOTE_HOST`
- `REMOTE_USER`
- `REMOTE_PATH`

Deploy-only secret:

- `SSH_PRIVATE_KEY`

Runtime variables:

- `OWNER_INIT_LOGIN`
- `APP_CONTACT_REQUESTS_ENABLED`
- `APP_DEBUG`
- `APP_DOMAIN`
- `APP_URL_SCHEMA`
- `APP_USE_CACHE`
- `AUTH_PUBLIC_KEY`
- `AUTH_TOKEN_EXPIRE_SECONDS`
- `AUTH_SESSION_EXPIRE_SECONDS`
- `AUTH_SESSION_ABSOLUTE_EXPIRE_SECONDS`
- `AUTH_TOKEN_HEADER_NAME`
- `AUTH_TOKEN_PREFIX`
- `CACHE_WARM_ARTICLES_PAGE_SIZE`
- `COMPETENCY_MATRIX_QUESTION_SUGGESTION_ANONYMOUS_DAILY_LIMIT`
- `DB_DRIVER`
- `DB_EXPIRE_ON_COMMIT`
- `DB_HOST`
- `DB_LOG_QUERY_METRICS`
- `DB_MAX_OVERFLOW`
- `DB_NAME`
- `DB_POOL_PRE_PING`
- `DB_POOL_SIZE`
- `DB_PORT`
- `DB_SLOW_QUERY_LOG_STATEMENT_MAX_LENGTH`
- `DB_SLOW_QUERY_LOG_THRESHOLD_MS`
- `DB_USER`
- `FILES_ORPHAN_RETENTION_SECONDS`
- `I18N_DEFAULT_LANGUAGE`
- `LE_EMAIL`
- `MINIO_HOST`
- `MINIO_PORT`
- `MINIO_REGION`
- `MINIO_CORS_MAX_AGE_SECONDS`
- `MINIO_PUBLIC_URL`
- `MINIO_SECURE`
- `SENTRY_USE`
- `SSL_CERT`
- `SSL_KEY`
- `TASKIQ_AUTH_SESSION_PRUNE_INTERVAL_SECONDS`
- `TASKIQ_AGENT_AUDIT_PRUNE_INTERVAL_SECONDS`
- `TASKIQ_CACHE_WARM_INTERVAL_SECONDS`
- `TASKIQ_FILE_ORPHAN_PRUNE_INTERVAL_SECONDS`
- `TASKIQ_RESULT_EXPIRE_SECONDS`
- `VALKEY_HOST`
- `VALKEY_PORT`
- `VPN_BIND_ADDRESS`

Runtime secrets:

- `OWNER_INIT_PASSWORD`
- `APP_SECRET_KEY`
- `AUTH_PRIVATE_KEY`
- `DB_PASSWORD`
- `MINIO_ACCESS_KEY`
- `MINIO_SECRET_KEY`
- `SENTRY_DSN`
- `AGENT_ACCESS_ISSUING_CERTIFICATE`
- `AGENT_ACCESS_ISSUING_PRIVATE_KEY`
- `AGENT_ACCESS_CERTIFICATE_CHAIN`

The deploy renderer still writes these values into the host-side runtime `.env`, but
the Compose helper materializes them as read-only files under `.deploy-state/compose-secrets/`
before Docker Compose starts. The secret directory is host-user-only, while the files keep a read bit
for non-root container UIDs because local Compose file-backed secrets are bind mounts.
`docker-compose.yml` grants those files to containers through Compose secrets. Backend processes
read the matching `/run/secrets/*` files at startup, PostgreSQL uses `POSTGRES_PASSWORD_FILE`, and
MinIO loads root credentials from secret files in its non-root wrapper image. Do not move these
values back into service `environment` entries or `env_file`, because those values are visible in
`docker inspect`.

MinIO runs as UID/GID `10002:10002`. During `make run`, the deploy script runs a transient
maintenance container as root to repair ownership on the `minio_data` volume before starting the
non-root MinIO runtime container. This keeps upgrades from older root-owned MinIO volumes working
without granting root to the long-running MinIO service.

Use `SSL_CERT=/certs/fullchain.pem` and `SSL_KEY=/certs/privkey.pem` for the compose-managed
certificate sync path. Keep deploy-only values such as `REMOTE_HOST`, `REMOTE_USER`,
`REMOTE_PATH`, `SSH_PRIVATE_KEY`, and registry passwords out of runtime `.env`.

The initial database migration creates the owner account from `OWNER_INIT_LOGIN` and
`OWNER_INIT_PASSWORD`. The migration runs once per database and uses an idempotent insert, so there
is no separate owner-init toggle.

Use `MINIO_HOST=minio` and `MINIO_PORT=9000` for the backend-internal S3 endpoint in the Compose
network. Use `MINIO_PUBLIC_URL=https://s3.<APP_DOMAIN>` for browser-facing object access and
computed public file URLs. `MINIO_REGION` must be explicit for SigV4 S3 client operations;
`us-east-1` is suitable for the bundled MinIO service unless deployment policy chooses another
region string. The Compose MinIO service derives `MINIO_API_CORS_ALLOW_ORIGIN` from
`APP_URL_SCHEMA` and `APP_DOMAIN` because the bundled MinIO release does not accept bucket-level
CORS setup through `PutBucketCors`.

Public files in the `media` bucket use database-backed orphan tracking. Set
`FILES_ORPHAN_RETENTION_SECONDS=604800` for the minimum seven-day grace period and
`TASKIQ_FILE_ORPHAN_PRUNE_INTERVAL_SECONDS=86400` for the daily TaskIQ schedule. A new upload is
an orphan until an article references it; removing or replacing the last article reference starts
a new grace period. Candidates become eligible only when `orphaned_at` is strictly older than the
calculated cutoff, so the cleanup never shortens the configured retention window.

Each task run locks and rechecks at most 100 oldest eligible metadata rows from the public `media`
namespace. It deletes the MinIO object before deleting its database metadata. A MinIO error keeps
the row and timestamp for the next scheduled retry, while a reference discovered during the final
check clears the stale orphan marker. The task deliberately does not list the bucket or remove
objects without database metadata; object/metadata reconciliation remains a separate operational
procedure. Run exactly one TaskIQ scheduler process, as defined by Compose, while workers may be
scaled independently.

## Admin Operational Tools

Owners and administrators use the operational tools widget directly on `/admin-panel/dashboard`;
the legacy `/admin-panel/workspace/tools` URL redirects there. The backing handlers stay under
`/api/admin/tools/*` and enforce the same team-management authorization in the backend. The widget
reports response-cache configuration and per-domain key/TTL metrics for `i18n`, `articles`, and
`competency_matrix`, plus expired and soon-expiring auth-session counts. Cache inspection uses
namespace-scoped Valkey scans, so it does not enumerate TaskIQ, auth, or other application keys.

Cache clear is synchronous, is limited to the three response-cache domains, and deliberately does
not enqueue a warm. Manual warm is asynchronous: the API creates a bounded-TTL operation record in
the TaskIQ results Valkey database, enqueues a manual wrapper around the shared full-warm service,
and the widget polls the operation through `queued`, `running`, `succeeded`, or `failed`. Operation
records use
`TASKIQ_RESULT_EXPIRE_SECONDS`; if a worker stops after accepting a task, a `queued` record can
remain until that TTL. Cache key/TTL metrics are an operational snapshot rather than a transactional
freshness guarantee.

Expired-session pruning uses the same use case as the scheduled TaskIQ cleanup. “Expiring soon” is
the server-owned seven-day window and counts only non-revoked sessions whose effective idle or
absolute expiration falls within it. Keep the TaskIQ worker and scheduler healthy even when manual
controls are available: the Dashboard widget is an operator tool, not a replacement for scheduled
maintenance.

## Private Agent API

Production exposes `https://agent.<APP_DOMAIN>:18083/internal/agent/v1` only on
`VPN_BIND_ADDRESS`. nginx requires a trusted client certificate, rate-limits by certificate
fingerprint, and proxies only the seven fixed REST operations to the normal backend upstream on the
private Compose network. Those routes are mounted in the main Litestar application but keep their
own machine authentication, scopes, exception mapping, request limit, transaction rollback, and
privacy-safe audit behavior. They are excluded from human PASETO authentication and OpenAPI. The
public `agent.<APP_DOMAIN>` host returns `404` outside the HTTP ACME challenge path; the normal
public listener also returns `404` for `/internal/agent/v1` and strips caller-supplied
`X-Agent-Client-Certificate` headers before proxying other backend routes.

Create a P-256 root CA offline and keep its private key off the production host. Use the root to
create a P-256 issuing CA, then provide the issuing certificate, issuing private key, and complete
chain through the three dedicated production secrets above. The deployment materializes them as
Compose secret files; do not move the issuing key into normal environment entries or an image.
The fail-closed helper accepts only absolute output directories outside the repository:

```bash
infra/scripts/agent_ca.sh init <offline-root-directory> <production-issuing-directory>
```

Each client generates its own P-256 private key and CSR locally. The owner registers the CSR and
least-privilege scopes in the owner-only admin workspace; the server never receives the client key.
Client keys must remain mode `0600`. Certificates last 90 days and the local stdio bridge starts a
recoverable two-phase rotation when 14 days or less remain. It persists the pending key and rotation
ID before the request, switches credentials atomically, and confirms with the replacement
certificate; only confirmation revokes the predecessor. Lost responses are retried with the same
rotation ID and key rather than weakening authentication.

Public DNS must contain `agent.<APP_DOMAIN>` for ACME, and the certificate request includes that SAN.
Trusted clients use split DNS or `/etc/hosts` to resolve the hostname to `VPN_BIND_ADDRESS`; they
must still validate the Let's Encrypt server certificate by hostname. The agent CA authenticates
clients and is not the server TLS trust bundle.

`make run` migrates the application database before starting the normal backend. The Agent contour
reuses the main settings, Dishka container, request session factory, `DB_*` identity, process,
secrets, and availability boundary; the backend receives the three issuing-CA secrets. The
supported contract is constrained by mTLS identity, scopes, exact REST routes, transport/core
validation, and operation-specific storages; it has only five business and two rotation operations,
with no publish, delete-item, generic CRUD, arbitrary fetch, shell, or SQL operation.

There is deliberately no separate Agent process or database role. Backend compromise, SQL
injection, or erroneous arbitrary SQL therefore has the main backend role's database blast radius,
can expose unrelated backend secrets, and can affect public/admin availability. A compromised
service that can reach the backend on the private application network can also forge the forwarded
certificate header. Treat the private network and nginx-to-backend hop as a trusted contour, and do
not describe shared composition as a security control. Deployment force-recreates nginx after the
new slot is healthy so changes to its port, secret, listener configuration, or image cannot be
missed by a config reload.

Before enabling agent work:

- Verify `18083/tcp` is bound only to the WireGuard address and cannot be reached on the public IP.
- Verify public `https://agent.<APP_DOMAIN>/internal/agent/v1/matrix/authoring-context` returns
  `404`, and verify a caller-supplied `X-Agent-Client-Certificate` is stripped on ordinary public
  backend requests.
- Verify an absent, expired, revoked, or wrong-scope certificate fails closed.
- Verify only the seven documented REST operations reach the Agent API; the local bridge still
  exposes only the five business tools documented in [Agent access](agent-access.md).
- Verify unsupported publish, delete, generic CRUD, and SQL routes do not exist and never proxy.
- Exercise client rotation before the first production certificate enters its rotation window.

If rollout or recovery fails, disable the private listener. Do not fall back to public
`443`, plaintext HTTP, shared certificates, bearer-only auth, a trusted client-certificate header
from direct callers, or generic admin/API access. See [Agent access](agent-access.md) for
client configuration, emergency response, and the full acceptance checklist.

## TLS

The manual deploy workflow exposes the `issue_certificates` boolean input. When selected, the
reusable deploy job runs `make certbot-issue` after syncing the new Compose/TLS configuration and
before `make run`, so a newly added hostname can be included before nginx starts with that
configuration. Leave the input disabled for ordinary deploys. The deploy startup script still syncs
certbot-owned certificates into `infra/nginx/certs/` for the unprivileged nginx container.

In production, keep routine renewal host-owned: a systemd timer or equivalent scheduler should run
`make certbot-renew` from the deployed project directory and let the target resync certificates and
reload nginx.

If certificates must be issued again on the server, run the maintenance target directly on the
host:

```bash
make certbot-issue
```

When the Compose nginx service is running, the target uses the shared ACME webroot and leaves nginx
on host port `80/tcp`. It then syncs the issued certificate and reloads nginx. On first boot, when
nginx is not running, the target falls back to Certbot's standalone HTTP challenge; in that case,
host port `80/tcp` must be free. Issuance is non-interactive and targets the `APP_DOMAIN` certificate
lineage explicitly, expanding it when the configured `s3` or `agent` subject alternative names are
new.

For certificate renewal on a running stack:

```bash
make certbot-renew
```

To resync existing certbot certificates without renewal:

```bash
make certbot-sync
```

## Server Expectations

The remote host needs Docker with the Compose plugin, `make`, `curl`, and SSH access for the
configured deploy user. The manual deploy job syncs `Makefile`, `docker-compose.yml`, `backend/`,
`frontend/`, `infra/`, and generated `.env`.

On a systemd-based VPS, Docker itself must be enabled at boot or no container restart policy can
run after a host reboot:

```bash
sudo systemctl enable docker.service
sudo systemctl is-enabled docker.service
```

## Restart and Edge Recovery

Long-running services use Docker restart policies so containers that were running before a Docker
daemon or VPS restart return when the enabled daemon starts again. Inactive blue/green backend and
frontend slots intentionally remain on `unless-stopped`, so a slot stopped by the deploy drain step
does not return unexpectedly. The public nginx edge uses `always`; `make run` force-recreates it and
verifies the effective restart policies of every active runtime container through `docker inspect`
before the edge smoke check.

Docker does not restart a container merely because its health status changes to `unhealthy`.
The nginx healthcheck therefore records consecutive failures of its loopback
`/nginx-healthz` endpoint in the existing `/tmp` tmpfs. After 12 failures, it sends `TERM` to nginx
PID 1; the `always` policy then starts the container again. A successful probe clears the failure
counter. The recurring probe deliberately checks local liveness only: nginx configuration validity
is checked during image/deploy validation and at process startup, avoiding a restart loop that
could replace a still-serving loaded configuration with an invalid on-disk configuration. This
recovery path needs neither a Docker socket mount nor a privileged watchdog container.

After deployment, verify the applied state with:

```bash
docker inspect competency_trainer_nginx \
  --format 'restart={{.HostConfig.RestartPolicy.Name}} status={{.State.Status}} health={{.State.Health.Status}} restarts={{.RestartCount}}'
docker inspect competency_trainer_nginx \
  --format '{{range .State.Health.Log}}{{println .End "exit=" .ExitCode .Output}}{{end}}'
```
