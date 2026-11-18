class NotificationService:
    async def enqueue(self, tenant_id: str, user_id: str, event_type: str,
                      dedupe_key: str, payload: dict):
        raise NotImplementedError  # TODO: preferences, persistence, dedupe, Celery
