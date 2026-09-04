# Competency Trainer Frontend

Angular hybrid SSR/CSR frontend for the portfolio and articles site. The frontend is packaged as an independent Docker image and runs the Angular Node.js SSR runtime: public article pages, the public site-build case study, the public updates page, and public competency matrix question pages are server-rendered for SEO, while protected admin content/team workspaces and interactive areas stay hydrated Angular.

In the full application stack, infrastructure nginx remains the public edge proxy:

- `/` is proxied to the frontend Node.js SSR container.
- `/api/*` is proxied to the backend service.
- `/sitemap.xml` and `/robots.txt` are proxied to backend-generated discovery endpoints.
- TLS, public domains, MinIO, and backup UI routing stay in the infrastructure layer.

## Development server

Use Node.js 24.16.0 for local frontend commands (`.nvmrc` matches CI). The production Docker
image uses its own pinned Node.js runtime documented below.

To start a local development server, run:

```bash
npm start
```

Once the server is running, open your browser and navigate to `http://localhost:4200/`. The application will automatically reload whenever you modify any of the source files.

## Building

Frontend Make targets prepare npm dependencies automatically when `node_modules` is missing or stale.

```bash
make build
```

The production build is written to `dist/competency-trainer-frontend/browser`.

SSR output is written to `dist/competency-trainer-frontend/server`. To build and run the public SEO HTML smoke check for public article pages, the site-build case study, the updates page, and matrix question pages, run:

```bash
make ssr-smoke
```

To build the production SSR bundle and run strict Lighthouse CI quality and performance gates for
the public SSR/CSR route sample, run:

```bash
make lighthouse
```

Reports are written to `performance/reports/lighthouse/`.

## Docker image

Build the frontend image from this directory:

```bash
docker build -t "competency_trainer_frontend:${IMAGE_TAG:?set IMAGE_TAG}" .
```

The image uses:

- `node:26.4.0-alpine` to install dependencies and run the Angular production build.
- `node:26.4.0-alpine` as the production runtime for `dist/competency-trainer-frontend/server/server.mjs`.
- Production dependencies are installed in the runtime stage, then npm/npx and the npm cache are removed from the final image because the server runtime only needs `node`.
- Explicit runtime environment: `PORT`, `SSR_API_ORIGIN`, `APP_URL_SCHEMA`, `APP_DOMAIN`, and optionally `SSR_PUBLIC_ORIGIN` / `NG_ALLOWED_HOSTS`.

Canonical SEO routes served by the frontend SSR runtime include `/ru/articles/:slug`, `/en/articles/:slug`, `/ru/how-this-site-is-built`, `/en/how-this-site-is-built`, `/ru/updates`, `/en/updates`, `/ru/competency-matrix/questions/:slug`, and `/en/competency-matrix/questions/:slug`. The matrix overview routes remain hydrated Angular pages.

## Repository split boundary

This directory is intended to become a standalone frontend repository later. Frontend-owned files should stay here, including Angular source code, public assets, the frontend Dockerfile, and the Angular SSR runtime entrypoint.

The frontend should not own TLS, public domain routing, backend proxy rules, sitemap/robots routing, MinIO routing, or backup service routing. Those belong to the infrastructure repository.

## Running unit tests

```bash
make test
```

## Linting

```bash
make lint
```
