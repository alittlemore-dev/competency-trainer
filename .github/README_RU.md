# Мой сайт

<p align="center">
  <img src="../frontend/public/logo-512x512.png" alt="Логотип проекта" width="180">
</p>

[🇺🇸 English version](./README.md)

| Категория | Технологии |
|----------|------------|
| Покрытие | ![coverage-backend](./badges/coverage-backend.svg) ![coverage-frontend](./badges/coverage-frontend.svg) |
| Backend | ![python](./badges/python.svg) ![litestar](./badges/litestar.svg) ![async](./badges/async.svg) ![pydantic](./badges/pydantic.svg) ![dishka](./badges/dishka.svg) ![taskiq](./badges/taskiq.svg) ![paseto](./badges/paseto.svg) ![argon2](./badges/argon2.svg) ![mcp](./badges/mcp.svg) |
| База данных | ![postgresql](./badges/postgresql.svg) ![sqlalchemy](./badges/sqlalchemy.svg) ![alembic](./badges/alembic.svg) |
| Кэш | ![valkey](./badges/valkey.svg) |
| Frontend | ![angular](./badges/angular.svg) ![typescript](./badges/typescript.svg) ![bootstrap](./badges/bootstrap.svg) |
| Тестирование | ![pytest](./badges/pytest.svg) ![jest](./badges/jest.svg) ![lhci](./badges/lhci.svg) |
| DevOps | ![docker](./badges/docker.svg) ![nginx](./badges/nginx.svg) ![minio](./badges/minio.svg) ![docker-compose](./badges/docker-compose.svg) |
| Качество | ![ruff](./badges/ruff.svg) ![mypy](./badges/mypy.svg) ![bandit](./badges/bandit.svg) ![pip-audit](./badges/pip-audit.svg) ![trivy](./badges/trivy.svg) ![hadolint](./badges/hadolint.svg) ![dockle](./badges/dockle.svg) ![vulture](./badges/vulture.svg) ![eslint](./badges/eslint.svg) ![prettier](./badges/prettier.svg) |
| Логирование | ![structlog](./badges/structlog.svg) ![ecs-logging](./badges/ecs-logging.svg) ![sentry](./badges/sentry.svg) |
| Архитектура | ![clean-architecture](./badges/clean-architecture.svg) ![type-safe](./badges/type-safe.svg) |
| Инструменты | ![uv](./badges/uv.svg) ![granian](./badges/granian.svg) ![node](./badges/node.svg) ![npm](./badges/npm.svg) |
| CI/CD | ![github-actions](./badges/github-actions.svg) ![dependabot](./badges/dependabot.svg) |

> [!NOTE]
> Backend coverage — pytest (Python). Frontend coverage — Jest (TypeScript). Оба генерируются в отдельных CI job-ах.

Инженерный сайт с публичной case-study страницей, обновлениями, матрицей компетенций,
локализованными статьями и защищёнными рабочими областями для управления контентом.

## 📖 Документация

- [Идея проекта](../docs/idea.md)  
- [Что нужно сделать](../docs/TODO.md)
- [Безопасный доступ агентов](../docs/agent-access.md)

## 📂 Структура проекта

```
competency-trainer/
├── infra/          # nginx reverse proxy, скрипты запуска
├── frontend/       # Angular 22 hybrid SSR/CSR (собственный Node.js-образ)
├── backend/        # Litestar API + доменная логика
│   ├── src/        # Исходный код приложения
│   ├── tests/      # Backend-тесты (pytest)
│   └── performance/ # сценарии и отчёты проверки планов PostgreSQL
├── .env.example    # Пример переменных окружения
├── .env.test       # Безопасные переменные для тестового окружения
├── docker-compose.test.yml
└── docker-compose.yml
```

## ✨ Возможности

- Матрица компетенций: локализованные листы, разделы и подразделы с управляемым приоритетом, поиск, табличная сетка, детальные ответы, публичные SEO-страницы вопросов, пикер и сортировка структуры в админке, внешние ресурсы
- Статьи: RU/EN-контент, папки, теги, поиск, фильтры по датам/тегам, управление публикацией и SSR-страницы публичных статей
- Защищённая панель владельца/администратора/модератора: создание, редактирование, публикация и снятие с публикации статей и вопросов матрицы, плюс управление командой, где администраторы управляют модераторами, а единственный владелец имеет полный доступ к команде
- Приватная аналитика статей: публичные счётчики просмотров, вовлечённые просмотры, категории источников и анонимные реакции
- Публичная case-study страница «как устроен сайт» про архитектуру, качество и эксплуатацию
- Публичная страница обновлений с milestone-изменениями сайта
- Локализация интерфейса и контента на русском и английском языках
- PASETO-аутентификация для защищённого режима владельца/администратора/модератора
  со скользящими, очищаемыми и управляемыми в админке серверными сесиями и
  блокировкой неактивных аккаунтов
- Приватный Agent-контур через WireGuard и nginx mTLS, смонтированный в основном Litestar
  приложении, и локальный stdio MCP bridge с пятью tools. Публичный listener скрывает внутренний
  route и удаляет поддельный certificate header, а mTLS-listener пропускает только семь точных REST
  операций. Раздельные сертификаты, scopes, закрытые routes и серверный Draft-контроль исключают
  публикацию, generic CRUD, произвольный fetch, shell, SQL и Docker-операции. Упрощённая композиция
  осознанно оставляет общими с backend процесс, роль БД, секреты и контур доступности.

## 🚀 Запуск

1. Клонировать репозиторий:
```bash
git clone git@github.com:alittlemore-dev/competency-trainer.git
cd competency-trainer
```

2. Создать файл `.env`:
```bash
cp .env.example .env
```

3. Сгенерировать сертификаты для `nginx` (опционально для локального запуска):

```bash
mkcert -install
mkcert \
  <your-domain> \
  s3.<your-domain> \
  agent.<your-domain>
mkdir -p ./infra/nginx/certs
mv <your-domain>.pem ./infra/nginx/certs/fullchain.pem
mv <your-domain>-key.pem ./infra/nginx/certs/privkey.pem
```

Контейнер nginx запускается с UID/GID `101:101`, поэтому смонтированные сертификат и приватный ключ
должны быть читаемы этим пользователем. Для локальных файлов `mkcert`
достаточно `chmod 644 ./infra/nginx/certs/<file>`; для production лучше настроить
owner/group-права так, чтобы доступ на чтение был только у nginx.
Production выпуск и renewal Let's Encrypt сертификатов идут через compose-backed
targets `make certbot-issue`, `make certbot-renew` и `make certbot-sync`. Подробнее:
[Production Deploy](../docs/production-deploy.md).

4. Обновить переменные в `.env`.

5. Запустить через `Makefile`:
```bash
make run
```

`make run` заранее проверяет обязательные значения `.env` и материализует runtime secrets как
локальные файлы `.deploy-state/compose-secrets/`. Затем он поднимает PostgreSQL, Valkey, MinIO,
Databasus, backend с ограниченным Agent route-контуром, frontend и nginx через Docker health checks,
выполняет одноразовую backend-инициализацию и переключает публичный трафик между blue/green
backend/frontend слотами с принудительным recreation nginx, чтобы применить Compose-изменения
порта, secrets, пользователя и image. Скрипт также проверяет фактические runtime restart policies:
nginx возвращается после перезапуска Docker/VPS и завершает себя после устойчивого отказа локальной
liveness-проверки, чтобы Docker восстановил edge без watchdog с Docker socket.

## Локальный MCP bridge

1. Запустить сайт через `make run` и один раз зарегистрировать клиентский CSR в
   `/admin-panel/workspace/agent-clients`.
2. Скопировать `.env.agent-bridge.example` в `.env.agent-bridge` и указать абсолютные пути к CA,
   выданному сертификату и приватному ключу.
3. Перезапустить Codex в этом репозитории. Checked-in конфигурация автоматически запустит stdio
   bridge с пятью tools; вручную экспортировать переменные не нужно.

Генерация сертификатов, desktop rotation и полная модель безопасности описаны в
[Agent Access](../docs/agent-access.md).

## ⚙️ Важные ссылки

Локальный edge nginx перенаправляет HTTP на HTTPS, поэтому в браузере используйте HTTPS-ссылки.

- Frontend: `https://localhost`
- API: `https://localhost/api`
- API liveness: `https://localhost/api/healthcheck`
- API readiness: `https://localhost/api/healthcheck/ready`
- Документация API: `https://localhost/api/docs`
- OpenAPI спецификация: `https://localhost/api/docs/openapi.json`

Внутренние web-панели доступны только через host-level WireGuard и nginx-порты,
привязанные к `VPN_BIND_ADDRESS`:

- MinIO Console: `http://<VPN_BIND_ADDRESS>:18081`
- Databasus: `http://<VPN_BIND_ADDRESS>:18082`
- Agent API: `https://agent.<APP_DOMAIN>:18083/internal/agent/v1` (WireGuard и активный клиентский
  сертификат; MCP bridge запускается локально через stdio)

Production firewall baseline: `80/tcp`, `443/tcp` и выбранный WireGuard UDP
port. Подробнее: [WireGuard internal access](../docs/wireguard-internal-access.md).

Другие сервисы — в [docker-compose.yml](../docker-compose.yml).

## 🧪 Тесты

```bash
make tests-compose              # запустить/переиспользовать test DB, backend + frontend, очистить своё
make tests-fast                 # backend unit + frontend tests; backend test DB не нужна
make tests                      # полный backend + frontend
make test-env-up                # запустить переиспользуемый test PostgreSQL
make test-env-down              # остановить test PostgreSQL и удалить данные
make test-backend               # backend unit + integration + serial migrations
make test-backend-unit          # unit-тесты backend, DB не нужна
make test-backend-integration   # интеграционные тесты backend, test DB готовится автоматически
make tests-coverage             # отчёт покрытия backend
make tests-coverage-frontend    # отчёт покрытия frontend
make test-frontend              # только frontend (jest)
make -C frontend ssr-smoke      # production SSR build + smoke HTML публичной статьи, обновлений, case-study и вопроса матрицы
make performance-lighthouse     # production Angular SSR build + strict Lighthouse CI quality/performance gates
make query-plans-realistic      # обязательный main gate: реалистичные данные, планы + latency
make query-plans-stress         # ручной большой профиль: строгие планы, latency как observation
```

Основной CI вызывает reusable query-plan workflow с профилем `realistic` и timeout 20 минут.
Отдельный ручной workflow **Query-plan profiles** принимает calibration-прогон `realistic` или
`stress`, использует timeout 45 минут и публикует артефакты `query-plan-reports-<profile>`.

Backend pytest targets запускаются с явным числом pytest-xdist воркеров по физическим CPU-ядрам,
без `-n auto`. Для serial-режима задайте `BACKEND_PYTEST_WORKERS=0` или `1`; любое значение больше
`1` принудительно задаёт точное число воркеров. Unit-тесты идут без test DB; integration-тесты
клонируют мигрированную template DB текущего запуска в отдельные PostgreSQL базы на worker, а
Alembic migration-тесты остаются serial на базовой test DB.
