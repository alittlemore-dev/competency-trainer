# Infrastructure

.PHONY: run
run:
	bash infra/scripts/run.sh

.PHONY: stop
stop:
	bash infra/scripts/stop.sh

.PHONY: certbot-issue
certbot-issue:
	bash infra/scripts/tls.sh issue

.PHONY: certbot-renew
certbot-renew:
	bash infra/scripts/tls.sh renew

.PHONY: certbot-sync
certbot-sync:
	bash infra/scripts/tls.sh sync

# Backend

.PHONY: install-backend
install-backend:
	$(MAKE) -C backend install

.PHONY: migrate
migrate:
	$(MAKE) -C backend migrate

.PHONY: downgrade
downgrade:
	$(MAKE) -C backend downgrade

.PHONY: revision
revision:
	$(MAKE) -C backend revision

.PHONY: test-backend
test-backend:
	$(MAKE) -C backend test

.PHONY: test-backend-fast
test-backend-fast:
	$(MAKE) -C backend test-unit

.PHONY: test-backend-unit
test-backend-unit:
	$(MAKE) -C backend test-unit

.PHONY: test-backend-unit-fast
test-backend-unit-fast:
	$(MAKE) -C backend test-unit

.PHONY: test-backend-integration
test-backend-integration:
	$(MAKE) -C backend test-integration

.PHONY: test-backend-integration-fast
test-backend-integration-fast:
	$(MAKE) -C backend test-integration

.PHONY: test-env-up
test-env-up:
	bash infra/scripts/test_env.sh up

.PHONY: test-env-down
test-env-down:
	bash infra/scripts/test_env.sh down

.PHONY: test-backend-compose
test-backend-compose:
	bash infra/scripts/tests_compose.sh backend

.PHONY: taskiq-worker
taskiq-worker:
	$(MAKE) -C backend taskiq-worker

.PHONY: taskiq-scheduler
taskiq-scheduler:
	$(MAKE) -C backend taskiq-scheduler

.PHONY: agent-bridge
agent-bridge:
	bash infra/scripts/agent_bridge.sh

.PHONY: tests-coverage
tests-coverage:
	$(MAKE) -C backend tests-coverage

.PHONY: tests-coverage-frontend
tests-coverage-frontend:
	$(MAKE) -C frontend tests-coverage

.PHONY: quality-backend
quality-backend:
	$(MAKE) -C backend quality

.PHONY: security-backend
security-backend:
	$(MAKE) -C backend security

# Frontend

.PHONY: install-frontend
install-frontend:
	$(MAKE) -C frontend install

.PHONY: test-frontend
test-frontend:
	$(MAKE) -C frontend test

.PHONY: quality-frontend
quality-frontend:
	$(MAKE) -C frontend quality

.PHONY: security-frontend
security-frontend:
	$(MAKE) -C frontend security

# Security

.PHONY: lint-dockerfiles
lint-dockerfiles:
	bash infra/scripts/docker_lint.sh hadolint

.PHONY: lint-docker-images
lint-docker-images:
	bash infra/scripts/docker_lint.sh dockle $(DOCKLE_IMAGE_REFS)

TRIVY_IMAGE := docker.io/aquasec/trivy:0.70.0@sha256:be1190afcb28352bfddc4ddeb71470835d16462af68d310f9f4bca710961a41e

.PHONY: security-trivy-config
security-trivy-config:
	bash infra/scripts/trivy_scan.sh config "$(TRIVY_IMAGE)"

.PHONY: security-backend-docker-image
security-backend-docker-image:
	bash infra/scripts/docker_image_security.sh \
		competency_trainer_application "$(IMAGE_TAG)" backend/Dockerfile backend "$(TRIVY_IMAGE)"

.PHONY: security-frontend-docker-image
security-frontend-docker-image:
	bash infra/scripts/docker_image_security.sh \
		competency_trainer_frontend "$(IMAGE_TAG)" frontend/Dockerfile frontend "$(TRIVY_IMAGE)"

.PHONY: security-nginx-docker-image
security-nginx-docker-image:
	bash infra/scripts/docker_image_security.sh \
		competency_trainer_nginx "$(IMAGE_TAG)" infra/nginx/Dockerfile . "$(TRIVY_IMAGE)"

.PHONY: security-infra
security-infra:
	bash infra/scripts/security_check.sh

.PHONY: security
security: security-backend security-frontend security-infra

# Combined

.PHONY: install
install: install-backend install-frontend

.PHONY: tests
tests: test-backend test-frontend

.PHONY: tests-fast
tests-fast: test-backend-fast test-frontend

.PHONY: tests-compose
tests-compose:
	bash infra/scripts/tests_compose.sh all

# Performance

.PHONY: performance-lighthouse
performance-lighthouse:
	$(MAKE) -C frontend lighthouse

.PHONY: query-plans-realistic
query-plans-realistic:
	$(MAKE) -C backend query-plans-realistic

.PHONY: query-plans-stress
query-plans-stress:
	$(MAKE) -C backend query-plans-stress

.PHONY: query-plans-baseline-candidate
query-plans-baseline-candidate:
	$(MAKE) -C backend query-plans-baseline-candidate

.PHONY: clean
clean:
	$(MAKE) -C backend clean
