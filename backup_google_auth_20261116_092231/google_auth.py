from fastapi import HTTPException
from google.auth.transport.requests import Request
from google.oauth2 import id_token
from app.config import settings


def verify_google_id_token(token: str) -> dict:
    if not settings.google_client_id:
        raise HTTPException(503, "Google authentication is not configured")
    if not token or len(token) > 12000:
        raise HTTPException(400, "Missing or invalid Google credential")
    try:
        claims = id_token.verify_oauth2_token(token, Request(), settings.google_client_id)
    except Exception:
        raise HTTPException(401, "Google identity verification failed")
    if claims.get("iss") not in ("accounts.google.com", "https://accounts.google.com"):
        raise HTTPException(401, "Invalid Google token issuer")
    if claims.get("email_verified") is not True:
        raise HTTPException(403, "Google email is not verified")
    subject = claims.get("sub")
    email = claims.get("email")
    if not subject or not email:
        raise HTTPException(401, "Google token is missing account identity")
    return {
        "google_sub": str(subject),
        "email": str(email).strip().lower(),
        "full_name": str(claims.get("name") or "").strip()[:160],
    }
