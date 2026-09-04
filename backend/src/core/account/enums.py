from core.enums import StrEnum


class ManagedAccountActionEnum(StrEnum):
    UPDATE_ROLE = "updateRole"
    UPDATE_PASSWORD = "updatePassword"  # noqa: S105  # nosec B105
    MANAGE_SESSIONS = "manageSessions"
    ACTIVATE = "activate"
    DEACTIVATE = "deactivate"
    DELETE = "delete"
