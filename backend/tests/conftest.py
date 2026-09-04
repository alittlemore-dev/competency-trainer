import uuid
from collections.abc import AsyncGenerator, Generator

import pytest
import pytest_asyncio
from sqlalchemy import NullPool
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

from infra.config.settings import Settings, settings
from scripts.pytest_parallel import build_worker_database_name


@pytest.fixture
def global_random_uuid() -> uuid.UUID:
    return uuid.uuid4()


@pytest.fixture
def global_random_hex_uuid(global_random_uuid: uuid.UUID) -> str:
    return global_random_uuid.hex


@pytest.fixture(scope="session")
def test_settings(worker_id: str) -> Generator[Settings]:
    original_use_cache = settings.app.use_cache
    original_database_name = settings.database.name
    settings.database.name = build_worker_database_name(
        base_database_name="competency_trainer_database_test",
        worker_id=worker_id,
    )
    settings.app.use_cache = False
    yield settings
    settings.app.use_cache = original_use_cache
    settings.database.name = original_database_name


@pytest.fixture(scope="session")
def worker_database() -> None:
    return None


@pytest_asyncio.fixture(loop_scope="session", scope="session")
async def engine(
    test_settings: Settings,
    worker_database: None,
) -> AsyncGenerator[AsyncEngine]:
    _ = test_settings, worker_database
    engine = create_async_engine(settings.database.url.get_secret_value(), poolclass=NullPool)
    yield engine
    await engine.dispose()
