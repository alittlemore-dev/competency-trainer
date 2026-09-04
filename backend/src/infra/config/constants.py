from pathlib import Path
from typing import Literal

from core.competency_matrix.schemas import QuestionQueueImportRules
from core.files.enums import FilePurpose
from core.files.schemas import FileRule, FileRules


class PathConstants:
    src_dir: Path = Path(__file__).resolve().parent.parent.parent
    root_dir: Path = src_dir.parent
    backend_env_file: Path = root_dir / ".env"
    repository_env_file: Path = root_dir.parent / ".env"
    env_file: Path = backend_env_file if backend_env_file.exists() else repository_env_file
    infra_dir: Path = src_dir / "infra"
    alembic_dir: Path = infra_dir / "postgresql" / "alembic"


class MinioBucketNamesConstants:
    media: Literal["media"] = "media"


class ValkeyDatabaseConstants:
    response_cache: int = 0
    auth_revocations: int = 1
    question_suggestion_quota: int = 2
    taskiq_broker: int = 3
    taskiq_results: int = 4


class ValkeyNamespaceConstants:
    admin_cache_warm_operations: str = "ADMIN_CACHE_WARM_OPERATIONS"
    auth_revocations: str = "AUTH_REVOCATIONS"
    framework: str = "LITESTAR"
    matrix_question_suggestions: str = "MATRIX_QUESTION_SUGGESTIONS"


class ValkeyConstants:
    databases: ValkeyDatabaseConstants = ValkeyDatabaseConstants()
    namespaces: ValkeyNamespaceConstants = ValkeyNamespaceConstants()
    missing_ttl_seconds: int = -2
    non_expiring_ttl_seconds: int = -1


class ResponseCacheConstants:
    store_name: Literal["litestar_cache"] = "litestar_cache"
    domain_key_separator: Literal[":"] = ":"
    default_ttl_seconds: int = 86_400
    status_scan_batch_size: int = 200
    json_content_type_header_name: bytes = b"content-type"
    json_content_type_header_value: bytes = b"application/json"


class TaskiqConstants:
    queue_name: Literal["competency_trainer_background"] = "competency_trainer_background"
    consumer_group_name: Literal["competency_trainer_background"] = "competency_trainer_background"
    result_prefix: Literal["competency_trainer_taskiq_results"] = (
        "competency_trainer_taskiq_results"
    )
    cache_warm_all_task_name: Literal["cache_warm_all"] = "cache_warm_all"
    cache_warm_domain_task_name: Literal["cache_warm_domain"] = "cache_warm_domain"
    manual_cache_warm_task_name: Literal["manual_cache_warm"] = "manual_cache_warm"
    cache_warm_operation_key_prefix: Literal["operation"] = "operation"
    cache_warm_latest_operation_key: Literal["latest"] = "latest"
    auth_session_prune_task_name: Literal["auth_session_prune"] = "auth_session_prune"
    agent_audit_prune_task_name: Literal["agent_audit_prune"] = "agent_audit_prune"
    file_orphan_prune_task_name: Literal["file_orphan_prune"] = "file_orphan_prune"


class FilesConstants:
    orphan_cleanup_batch_size: int = 100
    article_image_mime_types: frozenset[str] = frozenset(
        {"image/png", "image/jpeg", "image/webp", "image/gif"},
    )
    attachment_mime_types: frozenset[str] = frozenset({"*/*"})
    article_content_image_max_size_bytes: int = 5 * 1024 * 1024
    article_cover_image_max_size_bytes: int = 5 * 1024 * 1024
    cover_image_max_width_px: int = 1600
    cover_image_max_height_px: int = 900
    cover_image_webp_quality: int = 82
    cover_image_webp_method: int = 6
    cover_image_min_savings_ratio: float = 0.10
    content_image_max_width_px: int = 1920
    content_image_max_height_px: int = 1920
    content_image_jpeg_webp_quality: int = 88
    content_image_webp_method: int = 6
    content_image_min_savings_ratio: float = 0.10
    attachment_max_size_bytes: int = 20 * 1024 * 1024
    rules: FileRules = FileRules(
        values={
            FilePurpose.ARTICLE_CONTENT_IMAGE: FileRule(
                folder="article-content-images",
                allowed_mime_types=article_image_mime_types,
                max_size_bytes=article_content_image_max_size_bytes,
            ),
            FilePurpose.ARTICLE_COVER_IMAGE: FileRule(
                folder="article-cover-images",
                allowed_mime_types=article_image_mime_types,
                max_size_bytes=article_cover_image_max_size_bytes,
            ),
            FilePurpose.ATTACHMENT: FileRule(
                folder="attachments",
                allowed_mime_types=attachment_mime_types,
                max_size_bytes=attachment_max_size_bytes,
            ),
        },
    )


class SearchConstants:
    min_trigram_fuzzy_query_length: int = 6


class QuestionQueueImportConstants:
    rules: QuestionQueueImportRules = QuestionQueueImportRules(
        supported_text_extensions=frozenset({".txt", ".csv"}),
        supported_excel_extensions=frozenset({".xlsx", ".xlsm"}),
        unsupported_legacy_excel_extensions=frozenset({".xls"}),
        supported_extensions_for_message=(".txt", ".csv", ".xlsx", ".xlsm"),
        question_headers=frozenset({"question", "questions", "вопрос", "вопросы"}),
        question_headers_for_message=("question", "questions", "вопрос", "вопросы"),
        sheet_headers=frozenset({"sheet", "лист"}),
        grade_headers=frozenset({"grade", "грейд"}),
        csv_delimiters=",;\t|",
        question_max_length=255,
    )


class AdminValidationConstants:
    slug_pattern: str = r"^[a-z0-9]+(?:-[a-z0-9]+)*$"
    account_username_pattern: str = r"^[A-Za-z0-9._]+$"
    account_username_min_length: int = 3
    account_password_min_length: int = 8
    short_text_max_length: int = 255
    url_max_length: int = 2_048
    seo_description_max_length: int = 320
    email_max_length: int = 254
    article_content_max_length: int = 100_000
    matrix_long_text_max_length: int = 20_000


class AuthConstants:
    session_cookie_name: Literal["__Secure-msid"] = "__Secure-msid"
    session_cookie_path: Literal["/api/auth"] = "/api/auth"
    csrf_guard_header_name: Literal["X-CSRF-Guard"] = "X-CSRF-Guard"
    csrf_guard_header_value: Literal["1"] = "1"
    fetch_metadata_site_header_name: Literal["Sec-Fetch-Site"] = "Sec-Fetch-Site"
    fetch_metadata_cross_site_value: Literal["cross-site"] = "cross-site"
    no_store_header_value: Literal["no-store"] = "no-store"
    session_secret_byte_count: int = 32
    session_expiring_soon_days: int = 7


class AgentAccessConstants:
    api_path_prefix: str = "/internal/agent/v1"
    claim_ttl_seconds: int = 7_200
    minimum_resource_count: int = 1
    maximum_resource_count: int = 3
    certificate_lifetime_seconds: int = 90 * 24 * 60 * 60
    certificate_rotation_window_seconds: int = 14 * 24 * 60 * 60
    certificate_rotation_normal_access_overlap_seconds: int = 15 * 60
    csr_pem_max_length: int = 16_384
    request_body_max_size_bytes: int = 262_144
    audit_page_max_size: int = 100
    audit_retention_seconds: int = 365 * 24 * 60 * 60
    trusted_client_certificate_header: str = "X-Agent-Client-Certificate"
    request_id_header: str = "X-Request-ID"
    access_classification: Literal["future internal"] = "future internal"
    desktop_directory_mode: int = 0o700
    desktop_private_key_mode: int = 0o600
    desktop_pending_file_mode: int = 0o600


class Constants:
    path: PathConstants = PathConstants()
    minio_buckets: MinioBucketNamesConstants = MinioBucketNamesConstants()
    valkey: ValkeyConstants = ValkeyConstants()
    response_cache: ResponseCacheConstants = ResponseCacheConstants()
    taskiq: TaskiqConstants = TaskiqConstants()
    files: FilesConstants = FilesConstants()
    search: SearchConstants = SearchConstants()
    question_queue_import: QuestionQueueImportConstants = QuestionQueueImportConstants()
    admin_validation: AdminValidationConstants = AdminValidationConstants()
    auth: AuthConstants = AuthConstants()
    agent_access: AgentAccessConstants = AgentAccessConstants()


constants = Constants()
