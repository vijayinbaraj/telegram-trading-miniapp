import hashlib
import secrets
from datetime import datetime, timedelta, timezone
from fastapi import Header, HTTPException
from app.config import settings
from app.db import get_conn, fetch_one

ISSUER = "telegram-trading-miniapp"


def _digest(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def issue_session(user: dict) -> str:
    """Create an opaque, database-backed seven-day session. Only its hash is stored."""
    token = secrets.token_urlsafe(48)
    expires = datetime.now(timezone.utc) + timedelta(seconds=settings.session_ttl_seconds)
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO user_session (user_id, session_token, expires_at) VALUES (%s,%s,%s)",
                (user["id"], _digest(token), expires.replace(tzinfo=None)),
            )
            conn.commit()
    return token


def revoke_session(token: str) -> None:
    if not token:
        return
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("DELETE FROM user_session WHERE session_token=%s", (_digest(token),))
            conn.commit()

def revoke_user_sessions(user_id: int) -> None:
    """Logout revokes every active Mini App session for this Telegram-linked account."""
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("DELETE FROM user_session WHERE user_id=%s", (user_id,))
            conn.commit()


def require_user(authorization: str | None = Header(default=None)):
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(401, "Missing bearer token")
    token = authorization.split(" ", 1)[1].strip()
    if not token or len(token) > 256:
        raise HTTPException(401, "Invalid application session")
    row = fetch_one(
        """SELECT u.id,u.email,u.tenant_id,u.telegram_chat_id,u.paper_testing,u.is_active,
                  u.google_sub,u.full_name,s.expires_at
           FROM user_session s JOIN app_user u ON u.id=s.user_id
           WHERE s.session_token=%s AND s.expires_at>(NOW() AT TIME ZONE 'UTC')""",
        (_digest(token),),
    )
    if not row or not row["is_active"]:
        raise HTTPException(401, "Session expired or account inactive. Please log in again.")
    return row


def current_session_token(authorization: str | None) -> str:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(401, "Missing bearer token")
    return authorization.split(" ", 1)[1].strip()
