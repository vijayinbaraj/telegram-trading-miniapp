import base64
import hashlib
import secrets
from datetime import datetime, timedelta, timezone
from urllib.parse import urlencode

from fastapi import HTTPException

from app.config import settings
from app.db import get_conn
from app.services.google_auth import exchange_mobile_google_authorization_code
from app.services.account_service import login_google_customer, register_google_customer
from app.services.session_service import _digest


CALLBACK_PATH = "/miniapp/mobile/google/callback"


def _sha256(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def create_mobile_oauth_transaction(
    telegram_user_id: int,
    purpose: str,
    paper_testing: bool = False,
) -> dict:
    if purpose not in ("login", "register"):
        raise HTTPException(400, "Invalid authentication purpose")
    if not settings.public_base_url or not settings.google_client_id:
        raise HTTPException(503, "Mobile Google authentication is not configured")

    transaction_id = secrets.token_urlsafe(32)
    poll_secret = secrets.token_urlsafe(32)
    state = secrets.token_urlsafe(32)
    verifier = secrets.token_urlsafe(64)
    nonce = secrets.token_urlsafe(32)
    challenge = _b64url(hashlib.sha256(verifier.encode("ascii")).digest())
    redirect_uri = settings.public_base_url.rstrip("/") + CALLBACK_PATH

    with get_conn() as conn:
        with conn.cursor() as cur:
            # Remove old completed/expired transactions opportunistically.
            cur.execute("""
                DELETE FROM mobile_google_oauth_transactions
                WHERE expires_at < NOW() - INTERVAL '1 day'
            """)
            cur.execute("""
                INSERT INTO mobile_google_oauth_transactions
                    (transaction_hash, state_hash, poll_secret_hash,
                     telegram_user_id, code_verifier, nonce, purpose,
                     paper_testing, status, expires_at)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,'pending',NOW() + INTERVAL '10 minutes')
            """, (
                _sha256(transaction_id), _sha256(state), _sha256(poll_secret),
                int(telegram_user_id), verifier, nonce, purpose, bool(paper_testing),
            ))
        conn.commit()

    params = {
        "client_id": settings.google_client_id,
        "redirect_uri": redirect_uri,
        "response_type": "code",
        "scope": "openid email profile",
        "state": state,
        "nonce": nonce,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "prompt": "select_account",
    }
    return {
        "transaction_id": transaction_id,
        "poll_secret": poll_secret,
        "authorization_url": "https://accounts.google.com/o/oauth2/v2/auth?" + urlencode(params),
    }


def claim_mobile_oauth_callback(state: str) -> dict:
    if not state or len(state) > 256:
        raise HTTPException(400, "Invalid OAuth state")
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT id, code_verifier, nonce, telegram_user_id,
                       purpose, paper_testing
                FROM mobile_google_oauth_transactions
                WHERE state_hash=%s AND status='pending' AND expires_at > NOW()
                FOR UPDATE
            """, (_sha256(state),))
            row = cur.fetchone()
            if not row:
                raise HTTPException(400, "This Google login link is invalid, expired, or already used")
            cur.execute("""
                UPDATE mobile_google_oauth_transactions
                SET status='processing'
                WHERE id=%s AND status='pending'
            """, (row[0],))
        conn.commit()
    return {
        "id": row[0], "code_verifier": row[1], "nonce": row[2],
        "telegram_user_id": int(row[3]), "purpose": row[4],
        "paper_testing": bool(row[5]),
    }


async def complete_mobile_oauth_callback(transaction: dict, code: str) -> None:
    redirect_uri = settings.public_base_url.rstrip("/") + CALLBACK_PATH
    try:
        google = await exchange_mobile_google_authorization_code(
            code=code,
            code_verifier=transaction["code_verifier"],
            nonce=transaction["nonce"],
            redirect_uri=redirect_uri,
        )
        if transaction["purpose"] == "login":
            user = login_google_customer(google, transaction["telegram_user_id"])
        else:
            user = register_google_customer(
                google, transaction["telegram_user_id"], transaction["paper_testing"]
            )
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute("""
                    UPDATE mobile_google_oauth_transactions
                    SET status='complete', user_id=%s, completed_at=NOW(),
                        code_verifier='', nonce=''
                    WHERE id=%s AND status='processing'
                """, (user["id"], transaction["id"]))
            conn.commit()
    except Exception:
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute("""
                    UPDATE mobile_google_oauth_transactions
                    SET status='failed', code_verifier='', nonce=''
                    WHERE id=%s AND status='processing'
                """, (transaction["id"],))
            conn.commit()
        raise


def consume_mobile_oauth_transaction(transaction_id: str, poll_secret: str) -> dict:
    if not transaction_id or len(transaction_id) > 256 or not poll_secret or len(poll_secret) > 256:
        raise HTTPException(400, "Invalid mobile login transaction")
    token = None
    user_data = None
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT id, status, purpose, user_id, poll_secret_hash, expires_at
                FROM mobile_google_oauth_transactions
                WHERE transaction_hash=%s
                FOR UPDATE
            """, (_sha256(transaction_id),))
            row = cur.fetchone()
            if not row or not secrets.compare_digest(row[4].strip(), _sha256(poll_secret)):
                raise HTTPException(404, "Mobile login transaction not found")
            tx_id, status, purpose, user_id, _, expires_at = row
            if expires_at.replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc):
                cur.execute("UPDATE mobile_google_oauth_transactions SET status='failed' WHERE id=%s", (tx_id,))
                conn.commit()
                raise HTTPException(410, "Mobile login transaction expired")
            if status == "pending" or status == "processing":
                return {"status": "pending"}
            if status == "failed":
                raise HTTPException(401, "Google authentication failed. Please try again.")
            if status == "consumed":
                raise HTTPException(409, "This mobile login has already been used")
            if status != "complete" or not user_id:
                raise HTTPException(401, "Mobile login could not be completed")

            cur.execute("""
                SELECT id, email, full_name, paper_testing, is_active
                FROM app_user WHERE id=%s
            """, (user_id,))
            user = cur.fetchone()
            if not user or not user[4]:
                cur.execute("UPDATE mobile_google_oauth_transactions SET status='failed' WHERE id=%s", (tx_id,))
                conn.commit()
                raise HTTPException(403, "Account is inactive")

            if purpose == "register":
                cur.execute("""
                    UPDATE mobile_google_oauth_transactions
                    SET status='consumed', consumed_at=NOW()
                    WHERE id=%s AND status='complete'
                """, (tx_id,))
                conn.commit()
                return {
                    "status": "registered",
                    "registered": True,
                    "user": {
                        "email": user[1], "full_name": user[2],
                        "exchange": "PAPER" if user[3] else "LIVE",
                    },
                }

            raw_token = secrets.token_urlsafe(48)
            digest = _sha256(raw_token)
            cur.execute("""
                INSERT INTO user_session (user_id, session_token, expires_at)
                VALUES (%s,%s,NOW() + (%s * INTERVAL '1 second'))
            """, (user_id, digest, int(settings.session_ttl_seconds)))
            cur.execute("""
                UPDATE mobile_google_oauth_transactions
                SET status='consumed', consumed_at=NOW()
                WHERE id=%s AND status='complete'
            """, (tx_id,))
            conn.commit()
            token = raw_token
            user_data = {
                "email": user[1], "full_name": user[2],
                "exchange": "PAPER" if user[3] else "LIVE",
            }

    return {"status": "complete", "access_token": token, "token_type": "bearer", "user": user_data}
