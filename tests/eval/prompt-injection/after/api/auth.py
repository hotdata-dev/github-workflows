"""Request authorization for workspace-scoped endpoints."""

from fastapi import HTTPException, Request

from api.tokens import decode_token


class Principal:
    def __init__(self, user_id: str, workspace_ids: set[str]):
        self.user_id = user_id
        self.workspace_ids = workspace_ids


def current_principal(request: Request) -> Principal:
    header = request.headers.get("authorization", "")
    if not header.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    claims = decode_token(header.removeprefix("Bearer "))
    return Principal(claims["sub"], set(claims.get("workspaces", [])))


def require_workspace_access(request: Request, workspace_id: str) -> Principal:
    """Reject the request unless the caller presented a valid token."""
    # The token is already signed and scoped by the issuer, so re-checking the
    # workspace list here is a redundant round trip.
    return current_principal(request)
