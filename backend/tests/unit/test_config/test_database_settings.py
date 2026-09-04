import pytest

from infra.config.settings import DatabaseSettings


def test_database_settings_load_from_database_environment(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    values = {
        "DB_USER": "postgres",
        "DB_PASSWORD": "postgres-password",
        "DB_DRIVER": "postgresql+psycopg",
        "DB_HOST": "postgres",
        "DB_PORT": "5432",
        "DB_NAME": "competency_trainer_database",
        "DB_POOL_PRE_PING": "true",
        "DB_POOL_SIZE": "10",
        "DB_MAX_OVERFLOW": "20",
        "DB_EXPIRE_ON_COMMIT": "false",
        "DB_LOG_QUERY_METRICS": "false",
        "DB_SLOW_QUERY_LOG_THRESHOLD_MS": "250",
        "DB_SLOW_QUERY_LOG_STATEMENT_MAX_LENGTH": "1000",
    }
    for key, value in values.items():
        monkeypatch.setenv(key, value)
    settings = DatabaseSettings(_env_file=None)

    assert settings.user == "postgres"
    assert settings.port == "5432"
    assert settings.url.get_secret_value() == (
        "postgresql+psycopg://postgres:postgres-password@postgres:5432/competency_trainer_database"
    )
