from celery import Celery
from app.config import settings

celery_app = Celery("telegram_trading_bot", broker=settings.redis_url,
                    backend=settings.celery_result_backend)
celery_app.conf.update(
    task_serializer="json", result_serializer="json", accept_content=["json"],
    task_acks_late=True, task_reject_on_worker_lost=True,
    worker_prefetch_multiplier=1, task_track_started=True,
    task_routes={"app.tasks.notifications.*": {"queue": "notifications"}},
)
