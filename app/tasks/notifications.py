import httpx
from app.celery_app import celery_app
from app.config import settings
from app.db import fetch_one

@celery_app.task(bind=True, autoretry_for=(httpx.HTTPError,),
                 retry_backoff=True, retry_kwargs={"max_retries":5})
def deliver_telegram_notification(self, tenant_id:int, user_id:int, event_type:str,
                                  title:str, message:str, dedupe_key:str):
    user = fetch_one(
        """SELECT u.telegram_chat_id,p.trading_alerts,p.exceptions,p.account_notifications
           FROM app_user u LEFT JOIN telegram_notification_preferences p
             ON p.user_id=u.id AND p.tenant_id=u.tenant_id
           WHERE u.id=%s AND u.tenant_id=%s AND u.is_active=TRUE""",
        (user_id,tenant_id))
    if not user or not user["telegram_chat_id"]:
        return {"status":"skipped","reason":"unlinked"}
    pref = "exceptions" if event_type=="exception" else ("account_notifications" if event_type=="account" else "trading_alerts")
    if user[pref] is False: return {"status":"skipped","reason":"preference_disabled"}
    if not settings.telegram_bot_token: return {"status":"skipped","reason":"bot_token_missing"}
    response = httpx.post(f"https://api.telegram.org/bot{settings.telegram_bot_token}/sendMessage",
        json={"chat_id":str(user["telegram_chat_id"]),"text":f"{title}\n{message}"},timeout=10)
    if response.status_code == 429:
        raise httpx.HTTPStatusError("Telegram rate limited",request=response.request,response=response)
    response.raise_for_status()
    return {"status":"sent","dedupe_key":dedupe_key}
