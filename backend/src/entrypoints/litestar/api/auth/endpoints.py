from datetime import datetime
from typing import Annotated

from dishka import FromDishka
from dishka.integrations.litestar import DishkaRouter
from litestar import Controller, Request, Response, post, status_codes

from core.auth.enums import RoleEnum
from core.auth.exceptions import ForbiddenError, UnauthorizedError
from core.auth.schemas import (
    AccessTokenResult,
    AuthLoginParams,
    AuthLoginResult,
    AuthLogoutParams,
    AuthRefreshAccessTokenParams,
    AuthRefreshAccessTokenResult,
    AuthSessionClientMetadata,
    AuthSessionCredentials,
    AuthUseCaseConfig,
)
from core.auth.types import SessionSecret, Token
from core.auth.use_cases import AuthUseCase
from entrypoints.litestar.api.auth.schemas import AccessTokenResponseSchema, LoginRequestSchema
from entrypoints.litestar.api.parameters import api_json_body
from infra.config.constants import constants

_OPENAPI_PASSWORD_EXAMPLE = "string"  # noqa: S105  # nosec B105


def require_auth_cookie_csrf_guard(request: Request) -> None:
    csrf_guard = request.headers.get(constants.auth.csrf_guard_header_name)
    if csrf_guard != constants.auth.csrf_guard_header_value:
        raise ForbiddenError
    fetch_site = request.headers.get(constants.auth.fetch_metadata_site_header_name)
    if fetch_site == constants.auth.fetch_metadata_cross_site_value:
        raise ForbiddenError


def get_required_session_secret(request: Request) -> SessionSecret:
    session_secret = request.cookies.get(constants.auth.session_cookie_name)
    if session_secret is None:
        raise UnauthorizedError
    return SessionSecret(session_secret)


def get_optional_session_secret(request: Request) -> SessionSecret | None:
    session_secret = request.cookies.get(constants.auth.session_cookie_name)
    if session_secret is None:
        return None
    return SessionSecret(session_secret)


def create_access_token_response(
    *,
    result: AccessTokenResult,
) -> Response[AccessTokenResponseSchema]:
    return Response(
        content=AccessTokenResponseSchema.from_domain_schema(schema=result),
        headers={"Cache-Control": constants.auth.no_store_header_value},
    )


def set_session_cookie(
    *,
    response: Response[AccessTokenResponseSchema],
    session: AuthSessionCredentials,
) -> None:
    response.set_cookie(
        key=constants.auth.session_cookie_name,
        value=session.secret,
        max_age=session.expires_in_seconds,
        path=constants.auth.session_cookie_path,
        secure=True,
        httponly=True,
        samesite="lax",
    )


def create_login_response(*, result: AuthLoginResult) -> Response[AccessTokenResponseSchema]:
    response = create_access_token_response(result=result.access_token)
    set_session_cookie(response=response, session=result.session)
    return response


def create_refresh_response(
    *,
    result: AuthRefreshAccessTokenResult,
) -> Response[AccessTokenResponseSchema]:
    response = create_access_token_response(result=result.access_token)
    set_session_cookie(response=response, session=result.session)
    return response


def create_logout_response() -> Response[None]:
    response = Response(
        content=None,
        headers={"Cache-Control": constants.auth.no_store_header_value},
    )
    response.delete_cookie(
        key=constants.auth.session_cookie_name,
        path=constants.auth.session_cookie_path,
    )
    return response


class AuthApiController(Controller):
    path = "/auth"
    tags = ["auth"]

    @post(
        "/login",
        name="login-api-handler",
        description=(
            "Log in to the system. Creates a server-side session cookie and returns a "
            "short-lived PASETO access token."
        ),
        status_code=status_codes.HTTP_200_OK,
    )
    async def login(
        self,
        data: Annotated[
            LoginRequestSchema,
            api_json_body(
                title="Login request",
                description="Username and password used to create a PASETO access token.",
                examples=({"username": "moderator", "password": _OPENAPI_PASSWORD_EXAMPLE},),
            ),
        ],
        use_case: FromDishka[AuthUseCase],
        config: FromDishka[AuthUseCaseConfig],
        current_datetime: FromDishka[datetime],
        client_metadata: FromDishka[AuthSessionClientMetadata],
    ) -> Response[AccessTokenResponseSchema]:
        result = await use_case.login(
            config=config,
            params=AuthLoginParams(
                username=data.username,
                password=data.password,
                required_role=RoleEnum.MODERATOR,
                current_datetime=current_datetime,
                client_metadata=client_metadata,
            ),
        )
        return create_login_response(result=result)

    @post(
        "/refresh",
        name="refresh-api-handler",
        description="Refresh the short-lived access token from the server-side session cookie.",
        status_code=status_codes.HTTP_200_OK,
    )
    async def refresh(
        self,
        request: Request,
        use_case: FromDishka[AuthUseCase],
        config: FromDishka[AuthUseCaseConfig],
        current_datetime: FromDishka[datetime],
    ) -> Response[AccessTokenResponseSchema]:
        require_auth_cookie_csrf_guard(request)
        result = await use_case.refresh_access_token(
            config=config,
            params=AuthRefreshAccessTokenParams(
                session_secret=get_required_session_secret(request),
                required_role=RoleEnum.MODERATOR,
                current_datetime=current_datetime,
            ),
        )
        return create_refresh_response(result=result)

    @post(
        "/logout",
        name="logout-api-handler",
        description="Log out of the system. Revokes the current session and PASETO access token.",
        status_code=status_codes.HTTP_200_OK,
    )
    async def logout(
        self,
        request: Request,
        token: FromDishka[Token],
        use_case: FromDishka[AuthUseCase],
    ) -> Response[None]:
        require_auth_cookie_csrf_guard(request)
        await use_case.logout(
            params=AuthLogoutParams(
                token=token,
                session_secret=get_optional_session_secret(request),
            ),
        )
        return create_logout_response()


api_router = DishkaRouter("", route_handlers=[AuthApiController])
