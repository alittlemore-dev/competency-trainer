from datetime import datetime
from typing import Annotated

from dishka import FromDishka
from dishka.integrations.litestar import DishkaRouter
from litestar import Controller, Request, delete, get, post, put, status_codes
from litestar.datastructures import State
from litestar.di import NamedDependency, Provide

from core.account.schemas import (
    ManagedAccountCreateOperationParams,
    ManagedAccountFilters,
    ManagedAccountPasswordUpdateOperationParams,
    ManagedAccountRoleUpdateOperationParams,
    ManagedAccountSessionRevokeOperationParams,
    ManagedAccountSessionsOperationParams,
    ManagedAccountSessionsRevokeOthersOperationParams,
    ManagedAccountTargetOperationParams,
)
from core.account.use_cases import AccountsUseCase
from core.auth.exceptions import UnauthorizedError
from core.auth.schemas import JwtUser
from core.auth.token_handlers import TokenHandler
from core.auth.types import Token
from entrypoints.litestar.api.accounts.dependencies import provide_managed_account_filters
from entrypoints.litestar.api.accounts.schemas import (
    ManagedAccountCreateRequestSchema,
    ManagedAccountPasswordUpdateRequestSchema,
    ManagedAccountResponseSchema,
    ManagedAccountRoleUpdateRequestSchema,
    ManagedAccountSessionRevocationResponseSchema,
    ManagedAccountSessionsResponseSchema,
    ManagedAccountsResponseSchema,
)
from entrypoints.litestar.api.parameters import SessionIdPath, UsernamePath, api_json_body
from entrypoints.litestar.guards import team_manager_guard

_OPENAPI_PASSWORD_EXAMPLE = "string"  # noqa: S105  # nosec B105


class AdminAccountsApiController(Controller):
    path = "/accounts"
    tags = ["admin accounts"]
    guards = [team_manager_guard]

    @get(
        "",
        description="Get managed owner, admin and moderator accounts.",
        name="admin-accounts-list-api-handler",
        status_code=status_codes.HTTP_200_OK,
        dependencies={"filters": Provide(provide_managed_account_filters, sync_to_thread=False)},
    )
    async def list_accounts(
        self,
        use_case: FromDishka[AccountsUseCase],
        filters: NamedDependency[ManagedAccountFilters],
    ) -> ManagedAccountsResponseSchema:
        accounts = await use_case.list_accounts(filters=filters)
        return ManagedAccountsResponseSchema.from_domain_schema(schema=accounts)

    @post(
        "",
        description="Create a managed admin or moderator account.",
        name="admin-accounts-create-api-handler",
        status_code=status_codes.HTTP_201_CREATED,
    )
    async def create_account(
        self,
        data: Annotated[
            ManagedAccountCreateRequestSchema,
            api_json_body(
                title="Managed account creation request",
                description="Admin or moderator account creation payload.",
                examples=(
                    {
                        "username": "moderator",
                        "password": _OPENAPI_PASSWORD_EXAMPLE,
                        "role": "moderator",
                        "isActive": True,
                    },
                ),
            ),
        ],
        request: Request[JwtUser, Token | None, State],
        use_case: FromDishka[AccountsUseCase],
    ) -> ManagedAccountResponseSchema:
        account = await use_case.create_account(
            params=ManagedAccountCreateOperationParams(
                create_params=data.to_domain_schema(),
                current_username=request.user.username,
            ),
        )
        return ManagedAccountResponseSchema.from_domain_schema(schema=account)

    @get(
        "/{username:str}",
        description="Get managed account details.",
        name="admin-accounts-detail-api-handler",
        status_code=status_codes.HTTP_200_OK,
    )
    async def get_account(
        self,
        username: UsernamePath,
        use_case: FromDishka[AccountsUseCase],
    ) -> ManagedAccountResponseSchema:
        account = await use_case.get_account(username=username)
        return ManagedAccountResponseSchema.from_domain_schema(schema=account)

    @get(
        "/{username:str}/sessions",
        description="Get active managed account sessions.",
        name="admin-accounts-sessions-list-api-handler",
        status_code=status_codes.HTTP_200_OK,
    )
    async def list_account_sessions(
        self,
        username: UsernamePath,
        request: Request[JwtUser, Token | None, State],
        token_handler: FromDishka[TokenHandler],
        current_datetime: FromDishka[datetime],
        use_case: FromDishka[AccountsUseCase],
    ) -> ManagedAccountSessionsResponseSchema:
        sessions = await use_case.list_account_sessions(
            params=ManagedAccountSessionsOperationParams(
                target_username=username,
                current_username=request.user.username,
                current_session_id=self._current_session_id(
                    request=request,
                    token_handler=token_handler,
                ),
                current_datetime=current_datetime,
            ),
        )
        return ManagedAccountSessionsResponseSchema.from_domain_schema(schema=sessions)

    @post(
        "/{username:str}/sessions/{session_id:str}/revoke",
        description="Revoke a managed account session.",
        name="admin-accounts-session-revoke-api-handler",
        status_code=status_codes.HTTP_200_OK,
    )
    async def revoke_account_session(
        self,
        username: UsernamePath,
        session_id: SessionIdPath,
        request: Request[JwtUser, Token | None, State],
        token_handler: FromDishka[TokenHandler],
        use_case: FromDishka[AccountsUseCase],
    ) -> ManagedAccountSessionRevocationResponseSchema:
        result = await use_case.revoke_account_session(
            params=ManagedAccountSessionRevokeOperationParams(
                target_username=username,
                current_username=request.user.username,
                target_session_id=session_id,
                current_session_id=self._current_session_id(
                    request=request,
                    token_handler=token_handler,
                ),
            ),
        )
        return ManagedAccountSessionRevocationResponseSchema.from_domain_schema(schema=result)

    @post(
        "/{username:str}/sessions/revoke-all",
        description="Revoke all managed account sessions.",
        name="admin-accounts-sessions-revoke-all-api-handler",
        status_code=status_codes.HTTP_200_OK,
    )
    async def revoke_all_account_sessions(
        self,
        username: UsernamePath,
        request: Request[JwtUser, Token | None, State],
        token_handler: FromDishka[TokenHandler],
        current_datetime: FromDishka[datetime],
        use_case: FromDishka[AccountsUseCase],
    ) -> ManagedAccountSessionRevocationResponseSchema:
        result = await use_case.revoke_all_account_sessions(
            params=ManagedAccountSessionsOperationParams(
                target_username=username,
                current_username=request.user.username,
                current_session_id=self._current_session_id(
                    request=request,
                    token_handler=token_handler,
                ),
                current_datetime=current_datetime,
            ),
        )
        return ManagedAccountSessionRevocationResponseSchema.from_domain_schema(schema=result)

    @post(
        "/{username:str}/sessions/revoke-others",
        description="Revoke other sessions for the current managed account.",
        name="admin-accounts-sessions-revoke-others-api-handler",
        status_code=status_codes.HTTP_200_OK,
    )
    async def revoke_other_account_sessions(
        self,
        username: UsernamePath,
        request: Request[JwtUser, Token | None, State],
        token_handler: FromDishka[TokenHandler],
        use_case: FromDishka[AccountsUseCase],
    ) -> ManagedAccountSessionRevocationResponseSchema:
        result = await use_case.revoke_other_account_sessions(
            params=ManagedAccountSessionsRevokeOthersOperationParams(
                target_username=username,
                current_username=request.user.username,
                current_session_id=self._current_session_id(
                    request=request,
                    token_handler=token_handler,
                ),
            ),
        )
        return ManagedAccountSessionRevocationResponseSchema.from_domain_schema(schema=result)

    def _current_session_id(
        self,
        *,
        request: Request[JwtUser, Token | None, State],
        token_handler: TokenHandler,
    ) -> str:
        if request.auth is None:
            raise UnauthorizedError
        return token_handler.decode_token(request.auth).session_id

    @put(
        "/{username:str}/role",
        description="Update a managed account role.",
        name="admin-accounts-role-update-api-handler",
        status_code=status_codes.HTTP_200_OK,
    )
    async def update_role(
        self,
        username: UsernamePath,
        data: Annotated[
            ManagedAccountRoleUpdateRequestSchema,
            api_json_body(
                title="Managed account role update request",
                description="Role assigned to the managed account.",
                examples=({"role": "moderator"},),
            ),
        ],
        request: Request[JwtUser, Token | None, State],
        use_case: FromDishka[AccountsUseCase],
    ) -> ManagedAccountResponseSchema:
        account = await use_case.update_role(
            params=ManagedAccountRoleUpdateOperationParams(
                target_username=username,
                role_params=data.to_domain_schema(),
                current_username=request.user.username,
            ),
        )
        return ManagedAccountResponseSchema.from_domain_schema(schema=account)

    @put(
        "/{username:str}/password",
        description="Update a managed account password.",
        name="admin-accounts-password-update-api-handler",
        status_code=status_codes.HTTP_200_OK,
    )
    async def update_password(
        self,
        username: UsernamePath,
        data: Annotated[
            ManagedAccountPasswordUpdateRequestSchema,
            api_json_body(
                title="Managed account password update request",
                description="Replacement password for the managed account.",
                examples=({"password": _OPENAPI_PASSWORD_EXAMPLE},),
            ),
        ],
        request: Request[JwtUser, Token | None, State],
        use_case: FromDishka[AccountsUseCase],
    ) -> ManagedAccountResponseSchema:
        account = await use_case.update_password(
            params=ManagedAccountPasswordUpdateOperationParams(
                target_username=username,
                password_params=data.to_domain_schema(),
                current_username=request.user.username,
            ),
        )
        return ManagedAccountResponseSchema.from_domain_schema(schema=account)

    @post(
        "/{username:str}/activate",
        description="Activate a managed account.",
        name="admin-accounts-activate-api-handler",
        status_code=status_codes.HTTP_200_OK,
    )
    async def activate_account(
        self,
        username: UsernamePath,
        request: Request[JwtUser, Token | None, State],
        use_case: FromDishka[AccountsUseCase],
    ) -> ManagedAccountResponseSchema:
        account = await use_case.activate_account(
            params=ManagedAccountTargetOperationParams(
                target_username=username,
                current_username=request.user.username,
            ),
        )
        return ManagedAccountResponseSchema.from_domain_schema(schema=account)

    @post(
        "/{username:str}/deactivate",
        description="Deactivate a managed account.",
        name="admin-accounts-deactivate-api-handler",
        status_code=status_codes.HTTP_200_OK,
    )
    async def deactivate_account(
        self,
        username: UsernamePath,
        request: Request[JwtUser, Token | None, State],
        use_case: FromDishka[AccountsUseCase],
    ) -> ManagedAccountResponseSchema:
        account = await use_case.deactivate_account(
            params=ManagedAccountTargetOperationParams(
                target_username=username,
                current_username=request.user.username,
            ),
        )
        return ManagedAccountResponseSchema.from_domain_schema(schema=account)

    @delete(
        "/{username:str}",
        description="Delete a managed account.",
        name="admin-accounts-delete-api-handler",
        status_code=status_codes.HTTP_204_NO_CONTENT,
    )
    async def delete_account(
        self,
        username: UsernamePath,
        request: Request[JwtUser, Token | None, State],
        use_case: FromDishka[AccountsUseCase],
    ) -> None:
        await use_case.delete_account(
            params=ManagedAccountTargetOperationParams(
                target_username=username,
                current_username=request.user.username,
            ),
        )


admin_router = DishkaRouter("", route_handlers=[AdminAccountsApiController])
