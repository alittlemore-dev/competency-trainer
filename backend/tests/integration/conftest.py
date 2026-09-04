import os
from collections.abc import AsyncGenerator, Generator
from hashlib import sha1

import pytest
import pytest_asyncio
from sqlalchemy import create_engine, delete, text
from sqlalchemy.engine import URL, Connection, Engine
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.pool import NullPool

from infra.config.settings import Settings
from infra.postgresql import meta
from infra.postgresql.models import (
    AgentAuditEventModel,
    AgentCertificateModel,
    AgentCertificateRotationModel,
    AgentClientModel,
    ArticleDailyAnalyticsModel,
    ArticleFileUsageModel,
    ArticleModel,
    ArticleReactionModel,
    ArticleToTagSecondaryModel,
    CompetencyMatrixItemModel,
    ExternalResourceModel,
    FileModel,
    MatrixQuestionClaimModel,
    MatrixQuestionDraftCompletionModel,
    QueuedQuestionModel,
    TagModel,
    UserModel,
)
from infra.postgresql.query_monitoring import install_query_monitoring
from infra.postgresql.utils import downgrade, migrate
from scripts.pytest_parallel import build_template_database_name, quote_postgresql_identifier

_BASE_TEST_DATABASE_NAME = "competency_trainer_database_test"
_TEMPLATE_DATABASE_RUN_ID_ENV = "BACKEND_PYTEST_DB_TEMPLATE_ID"


@pytest.fixture(scope="session")
def worker_database(
    test_settings: Settings,
    worker_id: str,
    testrun_uid: str,
) -> Generator[None]:
    if worker_id == "master":
        yield
        return

    database_name = test_settings.database.name
    template_database_name = build_template_database_name(
        base_database_name=_BASE_TEST_DATABASE_NAME,
        run_id=os.environ.get(_TEMPLATE_DATABASE_RUN_ID_ENV, testrun_uid),
    )
    maintenance_engine = create_engine(
        _maintenance_database_url(test_settings),
        isolation_level="AUTOCOMMIT",
        poolclass=NullPool,
    )
    try:
        _ensure_template_database(
            engine=maintenance_engine,
            template_database_name=template_database_name,
            test_settings=test_settings,
        )
        _drop_database(engine=maintenance_engine, database_name=database_name)
        _create_database_from_template(
            engine=maintenance_engine,
            database_name=database_name,
            template_database_name=template_database_name,
        )
        yield
    finally:
        _drop_database(engine=maintenance_engine, database_name=database_name)
        maintenance_engine.dispose()


@pytest_asyncio.fixture(loop_scope="session", scope="session", autouse=True)
async def runtime_database_bindings(
    test_settings: Settings,
    worker_database: None,
) -> AsyncGenerator[None]:
    _ = worker_database
    original_engine = meta.engine
    original_sessionmaker = meta.sessionmaker
    worker_engine = create_async_engine(
        test_settings.database.url.get_secret_value(),
        pool_pre_ping=test_settings.database.pool_pre_ping,
        pool_size=test_settings.database.pool_size,
        max_overflow=test_settings.database.max_overflow,
    )
    install_query_monitoring(
        engine=worker_engine,
        enabled=test_settings.database.log_query_metrics,
        slow_query_log_threshold_ms=test_settings.database.slow_query_log_threshold_ms,
        statement_max_length=test_settings.database.slow_query_log_statement_max_length,
    )
    meta.engine = worker_engine
    meta.sessionmaker = async_sessionmaker(
        bind=worker_engine,
        class_=AsyncSession,
        expire_on_commit=test_settings.database.expire_on_commit,
    )
    try:
        yield
    finally:
        meta.sessionmaker = original_sessionmaker
        meta.engine = original_engine
        await worker_engine.dispose()


@pytest_asyncio.fixture(loop_scope="session", scope="session")
async def session_maker(engine: AsyncEngine) -> async_sessionmaker[AsyncSession]:
    return async_sessionmaker(bind=engine, class_=AsyncSession, expire_on_commit=False)


@pytest.fixture(scope="package")
def setup_migrations(
    engine: AsyncEngine,
    test_settings: Settings,
    worker_id: str,
) -> Generator[None]:
    _ = engine, test_settings
    if worker_id != "master":
        yield
        return

    migrate(revision="heads")
    yield
    downgrade(revision="base")


@pytest_asyncio.fixture
async def clear_tables(engine: AsyncEngine) -> None:
    async with engine.begin() as conn:
        await conn.execute(delete(AgentAuditEventModel))
        await conn.execute(delete(MatrixQuestionDraftCompletionModel))
        await conn.execute(delete(AgentCertificateRotationModel))
        await conn.execute(delete(MatrixQuestionClaimModel))
        await conn.execute(delete(AgentCertificateModel))
        await conn.execute(delete(AgentClientModel))
        await conn.execute(delete(QueuedQuestionModel))
        await conn.execute(delete(UserModel))
        await conn.execute(delete(ExternalResourceModel))
        await conn.execute(delete(CompetencyMatrixItemModel))
        await conn.execute(delete(ArticleFileUsageModel))
        await conn.execute(delete(ArticleReactionModel))
        await conn.execute(delete(ArticleDailyAnalyticsModel))
        await conn.execute(delete(ArticleToTagSecondaryModel))
        await conn.execute(delete(ArticleModel))
        await conn.execute(delete(FileModel))
        await conn.execute(delete(TagModel))


@pytest_asyncio.fixture
async def session(
    session_maker: async_sessionmaker[AsyncSession],
    setup_migrations: None,
    clear_tables: None,
) -> AsyncGenerator:
    _ = setup_migrations, clear_tables
    async with session_maker() as db:
        yield db
        await db.commit()


def _maintenance_database_url(test_settings: Settings) -> URL:
    return URL.create(
        drivername=test_settings.database.driver,
        username=test_settings.database.user,
        password=test_settings.database.password.get_secret_value(),
        host=test_settings.database.host,
        port=int(test_settings.database.port),
        database="postgres",
    )


def _create_database_from_template(
    engine: Engine,
    database_name: str,
    template_database_name: str,
) -> None:
    with engine.connect() as connection:
        connection.execute(
            text(
                f"CREATE DATABASE {quote_postgresql_identifier(database_name)} "
                f"TEMPLATE {quote_postgresql_identifier(template_database_name)}",
            ),
        )


def _drop_database(engine: Engine, database_name: str) -> None:
    with engine.connect() as connection:
        connection.execute(
            text(
                "SELECT pg_terminate_backend(pid) "
                "FROM pg_stat_activity "
                "WHERE datname = :database_name AND pid <> pg_backend_pid()",
            ),
            {"database_name": database_name},
        )
        connection.execute(
            text(f"DROP DATABASE IF EXISTS {quote_postgresql_identifier(database_name)}")
        )


def _ensure_template_database(
    engine: Engine,
    template_database_name: str,
    test_settings: Settings,
) -> None:
    lock_id = _template_database_lock_id(template_database_name=template_database_name)
    with engine.connect() as connection:
        connection.execute(text("SELECT pg_advisory_lock(:lock_id)"), {"lock_id": lock_id})
        try:
            if _database_exists(connection=connection, database_name=template_database_name):
                return

            connection.execute(
                text(f"CREATE DATABASE {quote_postgresql_identifier(template_database_name)}"),
            )
            _migrate_template_database(
                test_settings=test_settings,
                template_database_name=template_database_name,
            )
        finally:
            connection.execute(text("SELECT pg_advisory_unlock(:lock_id)"), {"lock_id": lock_id})


def _database_exists(connection: Connection, database_name: str) -> bool:
    result = connection.execute(
        text("SELECT 1 FROM pg_database WHERE datname = :database_name"),
        {"database_name": database_name},
    )
    return result.scalar_one_or_none() is not None


def _migrate_template_database(test_settings: Settings, template_database_name: str) -> None:
    original_database_name = test_settings.database.name
    test_settings.database.name = template_database_name
    try:
        migrate(revision="heads")
    finally:
        test_settings.database.name = original_database_name


def _template_database_lock_id(template_database_name: str) -> int:
    digest = sha1(
        f"pytest-template-db:{template_database_name}".encode(),
        usedforsecurity=False,
    ).digest()
    return int.from_bytes(digest[:8], byteorder="big") % ((2**63) - 1)
