from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.config import settings
from app.api.routes.health import router as health_router
from app.api.routes.miniapp import router as miniapp_router
from app.api.routes.telegram import router as telegram_router

app = FastAPI(
    title="Telegram Trading Bot + Mini App API",
    version="0.3.0",
)

allowed_origins = [
    origin.strip().rstrip("/")
    for origin in settings.google_allowed_origins.split(",")
    if origin.strip()
]

if settings.mini_app_url:
    mini_app_origin = settings.mini_app_url.strip().rstrip("/")
    if mini_app_origin not in allowed_origins:
        allowed_origins.append(mini_app_origin)

app.add_middleware(
    CORSMiddleware,
    allow_origins=allowed_origins,
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(health_router, prefix="/health", tags=["health"])
app.include_router(telegram_router, prefix="/telegram", tags=["telegram"])
app.include_router(miniapp_router, prefix="/miniapp", tags=["miniapp"])
