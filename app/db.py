from contextlib import contextmanager
import psycopg2
from psycopg2.extras import RealDictCursor
from app.config import settings

@contextmanager
def get_conn():
    conn = psycopg2.connect(
        dbname=settings.postgres_db, user=settings.postgres_user,
        password=settings.postgres_password, host=settings.postgres_host,
        port=settings.postgres_port, connect_timeout=5,
    )
    try:
        yield conn
    finally:
        conn.close()

def fetch_one(sql: str, params=()):
    with get_conn() as conn:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(sql, params)
            return cur.fetchone()

def fetch_all(sql: str, params=()):
    with get_conn() as conn:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(sql, params)
            return cur.fetchall()
