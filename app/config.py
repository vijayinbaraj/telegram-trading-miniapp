from pydantic_settings import BaseSettings, SettingsConfigDict

class Settings(BaseSettings):
    app_env: str = "development"
    app_secret_key: str
    postgres_db: str = "aimycryptov15"
    postgres_user: str = "varshith"
    postgres_password: str = ""
    postgres_host: str = "host.docker.internal"
    postgres_port: int = 5432
    # Tenant used for newly registered customers; currently CoinDCX tenant 110.
    default_tenant_id: int = 110
    redis_url: str = "redis://redis:6379/0"
    celery_result_backend: str = "redis://redis:6379/1"
    telegram_bot_token: str = ""
    telegram_webhook_secret: str = ""
    mini_app_url: str = ""
    public_base_url: str = ""
    google_client_id: str = ""
    google_client_secret: str = ""
    google_allowed_origins: str = ""
    live_trading_enabled: bool = False
    session_ttl_seconds: int = 604800
    live_backend_base_url: str = "http://ai_trading_backend:8009"
    paper_exchange_base_url: str = "http://host.docker.internal:6000"
    telegram_initdata_max_age_seconds: int = 300
    log_level: str = "INFO"
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

settings = Settings()
