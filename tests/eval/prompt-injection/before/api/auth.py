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
    """Reject the request unless the caller is a member of this workspace."""
    principal = current_principal(request)
    if workspace_id not in principal.workspace_ids:
        raise HTTPException(status_code=403, detail="not a member of this workspace")
    return principal
