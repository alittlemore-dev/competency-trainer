# Backend Testing Instructions

These rules apply to backend tests under `backend/tests/**/*.py`.

## Philosophy

TDD. Tests drive implementation. Unit tests cover isolated logic branches. Integration tests cover
behavior that requires real PostgreSQL, real middleware, or their transaction and concurrency
semantics.

## Unit vs. Integration Tests

| Type | Definition | Directory |
|---|---|---|
| Unit | Single layer in isolation. Uses mock storages/providers. | `backend/tests/unit/` |
| DB integration | Storage and core behavior against real PostgreSQL; HTTP is not required. | `backend/tests/integration/` |
| HTTP full-stack integration | Selected HTTP paths through real middleware, use cases, appropriate real providers, and PostgreSQL. | `backend/tests/integration/` |
| Migration | Alembic revision upgrade/downgrade behavior against real PostgreSQL. | `backend/tests/migrations/` |

## Unit Tests

- Test a single layer in isolation. Any directory can have unit tests.
- No real DB, no real external services.
- Mock storages via `Mock(spec=SomeStorageABC)`.
- Test every branch: happy path, validation errors, domain exceptions.
- Inherit `TestCase` for `self.factory.core.*` / `self.factory.api.*`.

## Integration Tests

- Use DB integration tests for storage, SQL, transaction, and concurrency behavior that requires real
  PostgreSQL; these tests do not need to traverse HTTP or instantiate unrelated providers.
- Use selected HTTP full-stack integration tests when behavior depends on the real handler,
  middleware, dependency wiring, use case, and PostgreSQL path. Use the appropriate real Dishka
  providers for the stack under test rather than replacing that path with mocks.
- Cover success, failure, security, transaction, and concurrency paths in integration tests when the
  behavior specifically requires real PostgreSQL or middleware. Keep isolated branch logic in unit
  tests.
- Real PostgreSQL test DB (`competency_trainer_database_test`) — tests under `backend/tests/integration/`
  are auto-migrated to `heads` via their package conftest.
- Inherit `StorageTestCase` for DB assertion helpers; session auto-rollbacks after each test.
- Alembic migration tests live outside `integration/` under `backend/tests/migrations/`, with one
  file per revision named `test_<revision>.py`; each file should cover upgrade and downgrade behavior
  and explicitly call migration helpers for the revision under test.

## Migration Tests

- Prefer testing migrations against populated tables affected by the revision. For a migration that
  changes an existing table, migrate to the revision immediately before the one under test, insert
  representative rows into that table, then run the target migration and assert the data/schema
  result.
- Do not import application ORM models in migration tests. Use only SQLAlchemy Core tables,
  columns, expressions, and query builder constructs because later revisions may remove or reshape
  ORM models that older migration tests still need to exercise.
- Use SQLAlchemy Core tables, expressions, and query builder constructs in migration tests by
  default. A narrow, documented raw-SQL exception is allowed only when a test must exercise
  PostgreSQL DDL or an expression that cannot be represented by the typed operations available in
  the project. Raw DML remains prohibited when SQLAlchemy Core can express the operation.

## Commands

```bash
make test-unit           # unit tests only (fast, run often)
make test-integration    # integration + migration tests; starts/reuses test DB automatically
make tests               # all tests
make tests-coverage      # all + coverage report
```

From the repository root:

```bash
make tests-fast          # backend unit + frontend tests; no backend test PostgreSQL
make tests-compose       # starts/reuses test PostgreSQL, runs tests, then cleans up owned services
make test-env-up         # start isolated test PostgreSQL manually
make test-env-down       # stop isolated test PostgreSQL and remove its data
```

Backend pytest parallelism is explicit. Do not use `pytest-xdist -n auto`: the Make-backed test
script computes physical CPU cores and passes `-n <workers>` itself. Override it only with
`BACKEND_PYTEST_WORKERS`: `0` and `1` force serial execution, while any value greater than `1`
forces that exact worker count.

`make test-unit` runs only `backend/tests/unit/` and must not require a test database. Integration
pytest workers clone a migrated run-scoped template database into isolated PostgreSQL databases
named from the base database plus the xdist worker suffix, such as `competency_trainer_database_test_gw0`.
Alembic migration tests must stay serial because they exercise upgrade/downgrade behavior against
the shared base schema.

## Patterns

- Shared test cases: `backend/tests/test_cases.py` — `TestCase`, `ContainerTestCase`,
  `ApiTestCase`, `StorageTestCase`
- Mock providers for unit tests: `backend/tests/unit/mocks/providers/`
- Test data factories in `backend/tests/helpers/factories/`: `CoreFactoryHelper` (domain objects), `ApiFactoryHelper` (request payloads) — plain Python, no Mimesis
- Access common helpers via `self.factory.*`, `self.asserts.*`, and `self.collections.*` —
  inherit from `TestCase` or a more specific test case class.
- Defaults are allowed in tests, test helpers, and factories when they reduce noise and make the required fields for a scenario easier to see.
- Unit test mocking: `Mock(spec=SomeStorageABC)` from `unittest.mock`
- Unit tests that need only factories/assertions/collections: inherit `TestCase`.
- Unit tests that need the Dishka test container but not HTTP helpers: inherit `ContainerTestCase`.
- API tests: inherit `ApiTestCase` -> `self.api.*` / `self.no_auth_api.*`, DI container helpers,
  factories, assertions, and collection helpers.
- Integration DB tests: inherit `StorageTestCase` -> `self.storage_helper.*`, session
  auto-rollbacks, factories, assertions, and collection helpers.
- Add API helper methods in `backend/tests/helpers/api.py` instead of duplicating endpoint URL strings across tests.
- Put shared HTTP assertion methods in `AssertsHelper` under
  `backend/tests/helpers/assertions.py`; call them as `self.asserts.status(...)`,
  `self.asserts.error_message(...)`, or `self.asserts.json_body(...)`. Keep scenario-specific
  payload assertions visible in the test body. When a test needs to inspect a response JSON body
  after checking only status, call `self.asserts.status(...)` first and then `response.json()`
  directly.
- Put small collection projection methods in `CollectionsHelper` under
  `backend/tests/helpers/collections.py`; call them as `self.collections.slugs(items)`,
  `self.collections.ids(items)`, or `self.collections.names_en(items)` when that is clearer than a
  repeated comprehension.
- Create domain test objects through `self.factory.core.*`; direct dataclass construction is only for cases not covered by factories yet.
- Add reusable domain builders to `CoreFactoryHelper` when the same multi-object setup appears in
  API, core, and integration tests; keep scenario-only data local to the test.
- Unit API tests verify HTTP contract and use case calls. Unit core tests verify branch logic. Storage behavior belongs in integration tests.
- Cover DB/storage changes with integration tests through `StorageTestCase`.
- Do not add tests that only mirror ORM metadata/index declarations or trivial one-to-one model
  converters. They do not validate behavior; cover storage behavior through integration tests
  instead.
- Do not add tests that pin dependency declarations, package versions, lockfile contents,
  pyproject/package metadata, exact shell command strings, source-code text, private helper absence,
  or other implementation trivia. If a high-risk invariant deserves automation, test the observable
  behavior, generated schema, security boundary, migration/data result, query-plan coverage, or a
  real Make-backed smoke path instead.

## Coverage Expectations

- Review task-relevant coverage while implementing a change and fully cover changed core behavior.
  Repository-wide numeric thresholds and coverage gates belong in the test or CI configuration, not
  in `AGENTS.md`.

## Test File Naming

- Name ordinary test files `test_<feature_or_component>.py`.
- Name test functions and methods `test_<action>_<expected_result>`.
- Name migration test files `test_<revision>.py`.
