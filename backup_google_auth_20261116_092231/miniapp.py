from fastapi import APIRouter, HTTPException, Depends, Header
from pydantic import BaseModel, ConfigDict, Field
from app.services.telegram_auth import validate_init_data
from app.services.google_auth import verify_google_id_token
from app.services.session_service import issue_session, require_user, revoke_user_sessions
from app.services.account_service import (
    find_linked_user, registration_status, register_google_customer, login_google_customer,
)
from app.services.connectivity_service import (
    get_profile, save_profile_credentials, test_telegram_connection, test_coindcx_connection,
)
from app.services.miniapp_service import dashboard, get_preferences, save_preferences, list_alerts
from app.services.telegram_bot import send_message, login_keyboard, authenticated_keyboard

router = APIRouter()

class GoogleAuthInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    init_data: str = Field(min_length=1, max_length=10000)
    credential: str = Field(min_length=1, max_length=12000)

class RegisterInput(GoogleAuthInput):
    paper_testing: bool

class PreferencesInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    trading_alerts: bool | None = None
    exceptions: bool | None = None
    account_notifications: bool | None = None

class ProfileCredentialsInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    coindcx_api_key: str | None = Field(default=None, max_length=512)
    coindcx_api_secret: str | None = Field(default=None, max_length=512)
    telegram_bot_token: str | None = Field(default=None, max_length=512)


def _telegram_identity(init_data: str):
    tg = validate_init_data(init_data)
    if not tg:
        raise HTTPException(401, "Invalid or expired Telegram Mini App data")
    return tg


@router.post("/auth/status")
def auth_status(body: dict):
    init_data = body.get("init_data", "") if isinstance(body, dict) else ""
    tg = _telegram_identity(init_data)
    state = registration_status(tg["telegram_user_id"])
    if state["status"] == "login":
        user = find_linked_user(tg["telegram_user_id"])
        from app.db import fetch_one
        active = fetch_one(
            "SELECT 1 AS ok FROM user_session WHERE user_id=%s AND expires_at>(NOW() AT TIME ZONE 'UTC') LIMIT 1",
            (user["id"],),
        )
        state["authenticated"] = bool(active)
    else:
        state["authenticated"] = False
    return state


@router.post("/register")
async def register(body: RegisterInput):
    tg = _telegram_identity(body.init_data)
    google = verify_google_id_token(body.credential)
    user = register_google_customer(google, tg["telegram_user_id"], body.paper_testing)
    try:
        await send_message(tg["telegram_user_id"], "Registration successful. Please log in with Google to continue.", login_keyboard())
    except Exception:
        pass  # Registration is committed; the next /start refreshes the keyboard.
    return {"ok": True, "registered": True, "message": "Registration successful. Return to Telegram and press Login.",
            "user": {"email": user["email"], "full_name": user.get("full_name"),
                     "exchange": "PAPER" if user["paper_testing"] else "LIVE"}}


@router.post("/login")
async def login(body: GoogleAuthInput):
    tg = _telegram_identity(body.init_data)
    google = verify_google_id_token(body.credential)
    user = login_google_customer(google, tg["telegram_user_id"])
    token = issue_session(user)
    try:
        await send_message(tg["telegram_user_id"], "Login successful. Your session is valid for seven days.", authenticated_keyboard())
    except Exception:
        pass  # The authenticated Mini App session is valid even if keyboard refresh fails.
    return {"ok": True, "access_token": token, "token_type": "bearer",
            "user": {"email": user["email"], "full_name": user.get("full_name"),
                     "exchange": "PAPER" if user["paper_testing"] else "LIVE"}}


@router.post("/auth")
def legacy_telegram_only_auth():
    raise HTTPException(410, "Telegram-only authentication has been replaced by Google login")


@router.post("/logout")
async def logout(authorization: str | None = Header(default=None), user=Depends(require_user)):
    revoke_user_sessions(user["id"])
    try:
        await send_message(user["telegram_chat_id"], "You have been logged out. Press Login to access your account again.", login_keyboard())
    except Exception:
        pass
    return {"ok": True, "message": "Logged out"}


@router.get("/dashboard")
def get_dashboard(user=Depends(require_user)):
    return dashboard(user)

@router.get("/settings")
def settings_view(user=Depends(require_user)):
    return {"preferences": get_preferences(user),
            "exchange": "PAPER" if user["paper_testing"] else "LIVE"}

@router.put("/settings/alerts")
def update_alert_preferences(body: PreferencesInput, user=Depends(require_user)):
    return {"preferences": save_preferences(user, body.model_dump(exclude_none=True))}

@router.get("/alerts")
def alerts(user=Depends(require_user)):
    return {"alerts": [dict(x) for x in list_alerts(user)]}

@router.get("/exceptions")
def exceptions(user=Depends(require_user)):
    return {"exceptions": [dict(x) for x in list_alerts(user, "exception")]}

@router.post("/exchange")
def switch_exchange(user=Depends(require_user)):
    raise HTTPException(503, "Exchange switching remains disabled until active-order and active-position safety checks are implemented.")

@router.get("/profile")
def profile(user=Depends(require_user)):
    return get_profile(user)

@router.put("/profile/credentials")
def update_profile_credentials(body: ProfileCredentialsInput, user=Depends(require_user)):
    return save_profile_credentials(user, body.coindcx_api_key, body.coindcx_api_secret,
                                    body.telegram_bot_token)

@router.post("/profile/test-telegram")
async def profile_test_telegram(user=Depends(require_user)):
    return await test_telegram_connection(user)

@router.post("/profile/test-exchange")
async def profile_test_exchange(user=Depends(require_user)):
    return await test_coindcx_connection(user)
