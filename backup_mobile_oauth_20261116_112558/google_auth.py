
import httpx

from fastapi import HTTPException
from google.auth.transport.requests import Request
from google.oauth2 import id_token

from app.config import settings


GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token"


def _validate_google_identity(claims: dict) -> dict:
    if claims.get("iss") not in (
        "accounts.google.com",
        "https://accounts.google.com",
    ):
        raise HTTPException(401, "Invalid Google token issuer")

    if claims.get("email_verified") is not True:
        raise HTTPException(403, "Google email is not verified")

    subject = claims.get("sub")
    email = claims.get("email")

    if not subject or not email:
        raise HTTPException(401, "Google identity is missing account information")

    return {
        "google_sub": str(subject),
        "email": str(email).strip().lower(),
        "full_name": str(claims.get("name") or "").strip()[:160],
    }


def verify_google_id_token(token: str) -> dict:
    """Retain existing Google ID-token authentication as a fallback."""

    if not settings.google_client_id:
        raise HTTPException(503, "Google authentication is not configured")

    if not token or len(token) > 12000:
        raise HTTPException(400, "Missing or invalid Google credential")

    try:
        claims = id_token.verify_oauth2_token(
            token,
            Request(),
            settings.google_client_id,
        )
    except Exception:
        raise HTTPException(401, "Google identity verification failed")

    return _validate_google_identity(claims)


async def exchange_google_authorization_code(
    code: str,
    origin: str | None,
    x_requested_with: str | None,
) -> dict:
    """Validate a GIS popup request, exchange its code, and verify identity."""

    if not settings.google_client_id or not settings.google_client_secret:
        raise HTTPException(503, "Google OAuth is not configured")

    if not code or len(code) > 4096:
        raise HTTPException(400, "Missing or invalid Google authorization code")

    # Require the Google Identity Services popup request header.
    if x_requested_with != "XmlHttpRequest":
        raise HTTPException(403, "Invalid Google OAuth popup request")

    # Only allow explicitly configured browser origins.
    allowed_origins = {
        item.strip().rstrip("/")
        for item in settings.google_allowed_origins.split(",")
        if item.strip()
    }

    if not origin or origin.rstrip("/") not in allowed_origins:
        raise HTTPException(403, "Unapproved Google OAuth origin")

    validated_origin = origin.rstrip("/")

    payload = {
        "code": code,
        "client_id": settings.google_client_id,
        "client_secret": settings.google_client_secret,
        "grant_type": "authorization_code",
        "redirect_uri": validated_origin,
    }

    try:
        async with httpx.AsyncClient(timeout=15.0) as client:
            response = await client.post(
                GOOGLE_TOKEN_URL,
                data=payload,
            )

        if response.status_code != 200:
            raise HTTPException(
                401,
                "Google authorization code exchange failed",
            )

        tokens = response.json()
        identity_token = tokens.get("id_token")

        if not identity_token:
            raise HTTPException(
                401,
                "Google did not return an identity token",
            )

        claims = id_token.verify_oauth2_token(
            identity_token,
            Request(),
            settings.google_client_id,
        )

        return _validate_google_identity(claims)

    except HTTPException:
        raise
    except Exception:
        raise HTTPException(401, "Google identity verification failed")
