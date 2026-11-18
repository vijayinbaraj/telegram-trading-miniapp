import hmac
from fastapi import APIRouter, Header, HTTPException, Request
from app.config import settings
from app.services.telegram_bot import handle_update

router = APIRouter()

@router.post("/webhook")
async def telegram_webhook(request: Request,
    x_telegram_bot_api_secret_token: str | None = Header(default=None)):
    expected = settings.telegram_webhook_secret
    if not expected or not x_telegram_bot_api_secret_token or not hmac.compare_digest(
        x_telegram_bot_api_secret_token, expected):
        raise HTTPException(403, "Forbidden")
    await handle_update(await request.json())
    return {"ok": True}
