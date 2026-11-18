
import httpx

from app.config import settings
from app.services.account_service import registration_status, find_linked_user
from app.db import fetch_one


API = f"https://api.telegram.org/bot{settings.telegram_bot_token}"


def _web_app_button(label: str):
    return {
        "text": label,
        "web_app": {
            "url": settings.mini_app_url
        }
    }


def registration_keyboard():
    return {
        "inline_keyboard": [[
            _web_app_button("Register"),
            _web_app_button("Login")
        ]]
    }


def login_keyboard():
    return {
        "inline_keyboard": [[
            _web_app_button("Login")
        ]]
    }


def authenticated_keyboard():
    return {
        "inline_keyboard": [[
            _web_app_button("Dashboard"),
            _web_app_button("Alerts")
        ]]
    }


async def send_message(chat_id, text, reply_markup=None):
    if not settings.telegram_bot_token:
        return

    payload = {
        "chat_id": chat_id,
        "text": text
    }

    if reply_markup:
        payload["reply_markup"] = reply_markup

    async with httpx.AsyncClient(timeout=10) as client:
        response = await client.post(
            f"{API}/sendMessage",
            json=payload
        )
        response.raise_for_status()


def _has_active_session(user_id: int) -> bool:
    return bool(fetch_one(
        """
        SELECT 1 AS ok
        FROM user_session
        WHERE user_id = %s
          AND expires_at > (NOW() AT TIME ZONE 'UTC')
        LIMIT 1
        """,
        (user_id,),
    ))


async def handle_update(update: dict):
    message = update.get("message") or update.get("edited_message")

    if not message:
        return

    chat_id = (message.get("chat") or {}).get("id")
    text = (message.get("text") or "").strip()

    if not chat_id or not text:
        return

    if text.startswith("/start"):
        state = registration_status(int(chat_id))["status"]
        user = find_linked_user(int(chat_id))

        if state == "unregistered":
            await send_message(
                chat_id,
                "Welcome! Register with Google or log in to your account.",
                registration_keyboard()
            )

        elif state in {"inactive", "blocked"}:
            await send_message(
                chat_id,
                "Your account cannot access this service. Please contact support."
            )

        elif user and _has_active_session(user["id"]):
            await send_message(
                chat_id,
                "Welcome back. Open your dashboard or alerts.",
                authenticated_keyboard()
            )

        else:
            await send_message(
                chat_id,
                "Welcome back. Please log in with Google to continue.",
                login_keyboard()
            )

        return

    user = find_linked_user(int(chat_id))

    if not user:
        await send_message(
            chat_id,
            "Please use /start to register or log in.",
            registration_keyboard()
        )
        return

    if not _has_active_session(user["id"]):
        await send_message(
            chat_id,
            "Your session has expired. Please log in again.",
            login_keyboard()
        )
        return

    if text.lower() in {"alerts", "dashboard"}:
        await send_message(
            chat_id,
            "Open the Mini App to view your " + text.lower() + ".",
            authenticated_keyboard()
        )

    elif text.lower() in {"/help", "help"}:
        await send_message(
            chat_id,
            "Use Dashboard or Alerts. Your login remains valid for seven days.",
            authenticated_keyboard()
        )

    else:
        await send_message(
            chat_id,
            "Use Dashboard or Alerts.",
            authenticated_keyboard()
        )
