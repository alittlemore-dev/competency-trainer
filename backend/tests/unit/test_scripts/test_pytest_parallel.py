from pathlib import Path

import pytest

from scripts.pytest_parallel import (
    build_template_database_name,
    build_worker_database_name,
    detect_pytest_worker_count,
    parse_lscpu_physical_core_count,
    quote_postgresql_identifier,
)


class TestPytestWorkerCount:
    def test_lscpu_parser_counts_physical_cores_once_for_hyperthread_rows(self) -> None:
        output = "# Core,Socket\n0,0\n0,0\n1,0\n1,0\n2,0\n3,0"

        assert parse_lscpu_physical_core_count(output) == 4

    @pytest.mark.parametrize(("override", "expected"), [("0", 0), ("1", 0), ("3", 3)])
    def test_env_override_controls_worker_count(self, override: str, expected: int) -> None:
        assert (
            detect_pytest_worker_count(
                env={"BACKEND_PYTEST_WORKERS": override},
                command_runner=CommandRunner(output="0,0\n0,0\n1,0\n1,0\n"),
                sysfs_cpu_root=Path("/missing"),
            )
            == expected
        )

    def test_invalid_env_override_raises_readable_error(self) -> None:
        with pytest.raises(
            ValueError, match="BACKEND_PYTEST_WORKERS must be a non-negative integer"
        ):
            detect_pytest_worker_count(
                env={"BACKEND_PYTEST_WORKERS": "many"},
                command_runner=CommandRunner(output="0,0\n"),
                sysfs_cpu_root=Path("/missing"),
            )

    def test_detects_physical_cores_from_lscpu_before_fallbacks(self) -> None:
        assert (
            detect_pytest_worker_count(
                env={},
                command_runner=CommandRunner(output="0,0\n0,0\n1,0\n1,0\n"),
                sysfs_cpu_root=Path("/missing"),
            )
            == 2
        )

    def test_fallback_does_not_return_logical_cpu_count(self) -> None:
        assert (
            detect_pytest_worker_count(
                env={},
                command_runner=CommandRunner(output="", raises=True),
                sysfs_cpu_root=Path("/missing"),
            )
            == 1
        )


class TestWorkerDatabaseName:
    def test_master_worker_uses_base_database_name(self) -> None:
        assert build_worker_database_name(
            base_database_name="competency_trainer_database_test", worker_id="master"
        ) == ("competency_trainer_database_test")

    def test_xdist_worker_uses_suffix(self) -> None:
        assert build_worker_database_name(
            base_database_name="competency_trainer_database_test", worker_id="gw0"
        ) == ("competency_trainer_database_test_gw0")

    @pytest.mark.parametrize("worker_id", ["gw-1", "worker 1", ""])
    def test_worker_database_name_rejects_unsafe_worker_ids(self, worker_id: str) -> None:
        with pytest.raises(ValueError, match="Unsafe PostgreSQL identifier"):
            build_worker_database_name(
                base_database_name="competency_trainer_database_test",
                worker_id=worker_id,
            )

    def test_worker_database_name_rejects_too_long_identifiers(self) -> None:
        with pytest.raises(ValueError, match="PostgreSQL identifier is too long"):
            build_worker_database_name(
                base_database_name="a" * 61,
                worker_id="gw0",
            )

    def test_quote_postgresql_identifier_quotes_valid_identifier(self) -> None:
        assert quote_postgresql_identifier("competency_trainer_database_test_gw0") == (
            '"competency_trainer_database_test_gw0"'
        )

    def test_quote_postgresql_identifier_rejects_unsafe_identifier(self) -> None:
        with pytest.raises(ValueError, match="Unsafe PostgreSQL identifier"):
            quote_postgresql_identifier("competency-trainer-database-test")


class TestTemplateDatabaseName:
    def test_template_database_name_uses_safe_hashed_run_suffix(self) -> None:
        database_name = build_template_database_name(
            base_database_name="competency_trainer_database_test",
            run_id="testrun-20260705",
        )

        assert database_name.startswith("competency_trainer_database_test_template_")
        assert "-" not in database_name
        assert len(database_name.encode("utf-8")) <= 63
        assert quote_postgresql_identifier(database_name) == f'"{database_name}"'

    def test_template_database_name_rejects_empty_run_id(self) -> None:
        with pytest.raises(ValueError, match="Template database run id must not be blank"):
            build_template_database_name(
                base_database_name="competency_trainer_database_test",
                run_id="   ",
            )


class CommandRunner:
    def __init__(self, output: str, raises: bool = False) -> None:
        self.output = output
        self.raises = raises

    def __call__(self, command: list[str]) -> str:
        if self.raises:
            raise FileNotFoundError(command[0])
        return self.output
