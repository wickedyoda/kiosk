"""
Kiosk Web Server

Serves a full-screen kiosk page with:
  - Left side: slideshow of photos from an Immich shared album
  - Right side: embedded Google Calendar in schedule (AGENDA) view

Photos are fetched from the Immich API via the shared link key (no user auth needed).
Thumbnails are cached locally (max 1GB) and removed when deleted from the album.
The calendar is embedded via an iframe to the Google Calendar public embed URL.
"""

import asyncio
import base64
import hashlib
import json
import logging
import logging.handlers
import os
import sys
import time
from contextlib import asynccontextmanager
from datetime import date, timedelta
from pathlib import Path
from urllib.parse import urlencode

import httpx
from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from jinja2 import Environment, FileSystemLoader, select_autoescape

# --- Logging configuration ---
LOG_LEVEL = os.environ.get("LOG_LEVEL", "DEBUG").upper()
LOG_DIR = Path(os.environ.get("LOG_DIR", "/app/logs"))
LOG_DIR.mkdir(parents=True, exist_ok=True)

# Determine numeric log level
_numeric_level = getattr(logging, LOG_LEVEL, logging.DEBUG)

# Configure root logger
logging.basicConfig(
    level=_numeric_level,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.handlers.RotatingFileHandler(
            LOG_DIR / "kiosk.log",
            maxBytes=50 * 1024 * 1024,  # 50MB per file
            backupCount=5,
        ),
    ],
)
logger = logging.getLogger("kiosk")

# --- Configuration from environment ---
IMMICH_URL = os.environ.get("IMMICH_URL", "https://photos.yourdomain.com").rstrip("/")
IMMICH_SHARED_LINK_KEY = os.environ.get("IMMICH_SHARED_LINK_KEY", "")
IMMICH_THUMB_SIZE = os.environ.get("IMMICH_THUMB_SIZE", "large")
SLIDESHOW_INTERVAL_MINUTES = int(os.environ.get("SLIDESHOW_INTERVAL_MINUTES", "15"))
GOOGLE_CALENDAR_URL = os.environ.get(
    "GOOGLE_CALENDAR_URL",
    "https://calendar.google.com/calendar/embed?src=d1hts4hbba10stq9eg2r0r52o8%40group.calendar.google.com&ctz=America%2FChicago&mode=AGENDA&showTitle=0&showPrint=0&showTabs=0&showCalendars=0&showTz=0&showNav=0&showDate=0&showAdd=0"
)
CALENDAR_REFRESH_INTERVAL_MINUTES = int(os.environ.get("CALENDAR_REFRESH_INTERVAL_MINUTES", "30"))
CALENDAR_SCALE = float(os.environ.get("CALENDAR_SCALE", "2"))
CALENDAR_INVERT = os.environ.get("CALENDAR_INVERT", "true").lower() in ("true", "1", "yes")
# Weather overlay settings
WEATHER_ZIP_CODE = os.environ.get("WEATHER_ZIP_CODE", "")
WEATHER_API_KEY = os.environ.get("WEATHER_API_KEY", "")
WEATHER_UNITS = os.environ.get("WEATHER_UNITS", "imperial")
WEATHER_REFRESH_MINUTES = max(int(os.environ.get("WEATHER_REFRESH_MINUTES", "240")), 120)  # default 4h, min 2h
WEATHER_API_LIMIT_ENABLED = os.environ.get("WEATHER_API_LIMIT_ENABLED", "true").lower() in ("true", "1", "yes")
WEATHER_API_DAILY_LIMIT = int(os.environ.get("WEATHER_API_DAILY_LIMIT", "999"))  # hard cap on API calls per 24h
PAGE_REFRESH_INTERVAL_MINUTES = int(os.environ.get("PAGE_REFRESH_INTERVAL_MINUTES", "30"))
TRUST_PROXY = os.environ.get("TRUST_PROXY", "false").lower() in ("true", "1", "yes")
BASE_URL = os.environ.get("BASE_URL", "").rstrip("/")

# Data and cache paths — inside the container, always /app/data
DATA_DIR = Path(os.environ.get("DATA_PATH", "/app/data"))
CACHE_DIR = DATA_DIR / "thumbnails"
CACHE_DIR.mkdir(parents=True, exist_ok=True)

# Cache limits
MAX_CACHE_SIZE_BYTES = int(
    os.environ.get("CACHE_MAX_SIZE_MB", "1024")
) * 1024 * 1024  # default 1GB
CACHE_TTL_SECONDS = int(os.environ.get("CACHE_MAX_AGE_SECONDS", "86400"))  # 24h default

# --- Jinja2 environment for inline HTML rendering ---
env = Environment(
    loader=FileSystemLoader("templates"),
    autoescape=select_autoescape(["html"]),
    auto_reload=True,
)


# ---------------------------------------------------------------------------
# Calendar URL helper — adds date range to filter events
# ---------------------------------------------------------------------------

CALENDAR_WEEKS_AHEAD = int(os.environ.get("CALENDAR_WEEKS_AHEAD", "3"))


def build_calendar_url(base_url: str, weeks_ahead: int = 3) -> str:
    """Build a Google Calendar embed URL with a date range filter.

    Adds a 'dates' parameter to show only events within the specified
    number of weeks from today. This prevents the calendar from showing
    events far in the future.
    """
    today = date.today()
    start_date = today.strftime("%Y%m%d")
    end_date = (today + timedelta(weeks=weeks_ahead)).strftime("%Y%m%d")
    dates_param = f"dates={start_date}/{end_date}"

    # Append dates param to the URL
    if "?" in base_url:
        return f"{base_url}&{dates_param}"
    else:
        return f"{base_url}?{dates_param}"


# ---------------------------------------------------------------------------
# Cache management
# ---------------------------------------------------------------------------

def _asset_cache_path(asset_id: str) -> Path:
    """Return the local file path for a cached asset thumbnail."""
    return CACHE_DIR / f"{asset_id}.jpg"


def _cache_cleanup():
    """Remove stale cache entries (older than CACHE_TTL_SECONDS) and enforce size limit."""
    now = time.time()
    removed = 0
    freed = 0

    # Delete stale files
    for f in CACHE_DIR.glob("*.jpg"):
        try:
            mtime = f.stat().st_mtime
            if now - mtime > CACHE_TTL_SECONDS:
                freed += f.stat().st_size
                f.unlink()
                removed += 1
        except OSError:
            pass

    # Enforce max cache size (LRU eviction)
    while True:
        total = sum(f.stat().st_size for f in CACHE_DIR.glob("*.jpg"))
        if total <= MAX_CACHE_SIZE_BYTES:
            break
        # Remove oldest by mtime
        oldest = min(CACHE_DIR.glob("*.jpg"), key=lambda f: f.stat().st_mtime)
        total -= oldest.stat().st_size
        oldest.unlink()
        removed += 1
        freed += oldest.stat().st_size

    if removed:
        logger.info("Cache cleanup: removed %d files, freed %.1f MB", removed, freed / (1024 * 1024))


def _cache_sync(current_ids: set[str]):
    """Remove cache entries for assets no longer in the album."""
    current_ids_lower = current_ids
    removed = 0
    for f in CACHE_DIR.glob("*.jpg"):
        asset_id = f.stem
        if asset_id not in current_ids_lower:
            f.unlink()
            removed += 1
    if removed:
        logger.info("Cache sync: removed %d stale entries", removed)


# ---------------------------------------------------------------------------
# Immich API
# ---------------------------------------------------------------------------

async def _fetch_album_assets(
    client: httpx.AsyncClient,
    api_base: str,
    auth_params: dict,
    album_id: str,
) -> list[dict]:
    """
    Fetch all assets from an Immich album via search/metadata.
    Returns list of asset dicts with at least 'id' key.
    """
    assets = []
    page = 1
    page_size = 100

    while True:
        payload = {
            "albumIds": [album_id],
            "size": page_size,
            "page": page,
        }
        resp = await client.post(
            f"{api_base}/search/metadata",
            params=auth_params,
            json=payload,
        )

        if resp.status_code != 200:
            logger.error(
                "Failed to fetch album assets: HTTP %s — %s",
                resp.status_code,
                resp.text[:200],
            )
            break

        data = resp.json()
        items = data.get("assets", {}).get("items", [])

        for item in items:
            assets.append(item)

        # Stop if we got fewer items than the page size
        if len(items) < page_size:
            break
        page += 1

    return assets


async def _cache_asset(client: httpx.AsyncClient, api_base: str, auth_params: dict, asset_id: str) -> str:
    """Download and cache a thumbnail locally. Returns the local proxy URL."""
    cache_path = _asset_cache_path(asset_id)
    proxy_url = f"/photo/{asset_id}"

    # If already cached and fresh, return proxy URL
    if cache_path.exists():
        cache_path.touch()  # update mtime
        return proxy_url

    # Download the thumbnail
    thumb_url = f"{api_base}/assets/{asset_id}/thumbnail"
    resp = await client.get(thumb_url, params=auth_params)
    if resp.status_code != 200:
        logger.warning("Failed to download thumbnail for %s: HTTP %s", asset_id, resp.status_code)
        return proxy_url  # return proxy URL anyway; the proxy endpoint will return placeholder on miss

    cache_path.write_bytes(resp.content)
    logger.debug("Cached thumbnail for %s (%.1f KB)", asset_id, len(resp.content) / 1024)
    return proxy_url


# Cache for photo URLs — refreshed on each API call
_cached_photos: list[str] | None = None
_cached_asset_ids: set[str] | None = None
_last_fetch: float = 0
_cache_ttl = 60  # seconds


async def fetch_immich_photos() -> list[str]:
    """
    Fetch all asset thumbnail URLs from the Immich shared link.

    Flow:
      1. GET /api/shared-links/me?key={key} — resolves the shared link key to
         a SharedLinkResponseDto containing the album ID.
      2. POST /api/search/metadata?key={key} with albumIds filter — fetches
         all assets in the album (paginated).
      3. Cache thumbnails locally via the proxy endpoint.
      4. Build local proxy URLs: /photo/{assetId}

    The shared link key acts as auth for these endpoints — no API key needed.
    """
    global _cached_photos, _cached_asset_ids, _last_fetch

    now = time.time()
    if _cached_photos is not None and (now - _last_fetch) < _cache_ttl:
        return _cached_photos

    if not IMMICH_SHARED_LINK_KEY:
        logger.warning("IMMICH_SHARED_LINK_KEY is not set; photo list will be empty")
        _cached_photos = []
        _cached_asset_ids = set()
        _last_fetch = now
        return _cached_photos

    api_base = f"{IMMICH_URL}/api"
    auth_params = {"key": IMMICH_SHARED_LINK_KEY}

    try:
        async with httpx.AsyncClient(timeout=30, follow_redirects=True) as client:
            # Step 1: Get the shared link info (to find the album ID)
            logger.info("Fetching shared link info from %s", f"{api_base}/shared-links/me")
            resp = await client.get(f"{api_base}/shared-links/me", params=auth_params)

            if resp.status_code != 200:
                logger.error(
                    "Failed to fetch shared link: HTTP %s — %s",
                    resp.status_code,
                    resp.text[:200],
                )
                _cached_photos = []
                _cached_asset_ids = set()
                _last_fetch = now
                return _cached_photos

            link_data = resp.json()
            album = link_data.get("album")

            # If the shared link already has assets in the response, use those
            assets = link_data.get("assets", [])

            if not assets and album and album.get("id"):
                # Fallback: search for assets in the album via search/metadata endpoint
                album_id = album["id"]
                logger.info("Fetching assets for album %s via search/metadata", album_id)
                raw_assets = await _fetch_album_assets(client, api_base, auth_params, album_id)
                # Convert to the format expected below
                assets = [{"id": a["id"]} for a in raw_assets]
            elif assets:
                assets = [{"id": a["id"]} for a in assets]

            if not assets:
                logger.warning("No assets found in shared link")
                _cached_photos = []
                _cached_asset_ids = set()
                _last_fetch = now
                return _cached_photos

            # Cache thumbnails and build proxy URLs
            photo_urls = []
            current_asset_ids = set()
            for asset in assets:
                asset_id = asset.get("id")
                if asset_id:
                    current_asset_ids.add(asset_id)
                    proxy_url = await _cache_asset(client, api_base, auth_params, asset_id)
                    photo_urls.append(proxy_url)

            # Sync cache: remove entries for assets no longer in album
            _cache_sync(current_asset_ids)
            # Cleanup stale/oversized cache
            _cache_cleanup()

            logger.info("Fetched %d photos from Immich album, cached thumbnails", len(photo_urls))
            _cached_photos = photo_urls
            _cached_asset_ids = current_asset_ids
            _last_fetch = now
            return _cached_photos
    except (httpx.ConnectError, httpx.TimeoutException, httpx.HTTPError) as e:
        logger.error("Error fetching photos from Immich: %s", e)
        _cached_photos = []
        _cached_asset_ids = set()
        _last_fetch = now
        return _cached_photos


# ---------------------------------------------------------------------------
# Weather API
# ---------------------------------------------------------------------------

_WEATHER_CACHE: dict | None = None
_WEATHER_CACHE_TIME: float = 0
_WEATHER_CACHE_TTL = 240 * 60  # 4 hours (OpenWeatherMap free tier rate limit: min 2h between calls)

# Rate limiting for OpenWeatherMap API calls (hard cap per 24h)
_WEATHER_CALL_COUNT = 0
_WEATHER_CALL_TRACKING_START: float | None = None


def _check_weather_api_limit() -> bool:
    """Check if we've exceeded the daily API call limit.

    Returns True if calls are allowed, False if limit exceeded.
    Resets the counter every 24 hours.
    """
    global _WEATHER_CALL_COUNT, _WEATHER_CALL_TRACKING_START
    now = time.time()

    # Reset tracking window every 24 hours
    if _WEATHER_CALL_TRACKING_START is None or (now - _WEATHER_CALL_TRACKING_START) >= 86400:
        _WEATHER_CALL_COUNT = 0
        _WEATHER_CALL_TRACKING_START = now

    if _WEATHER_CALL_COUNT >= WEATHER_API_DAILY_LIMIT:
        logger.warning(
            "Weather API limit reached: %d calls in 24h (enabled=%s)",
            _WEATHER_CALL_COUNT, WEATHER_API_LIMIT_ENABLED
        )
        return False

    return True


def _increment_weather_calls():
    """Increment the weather API call counter."""
    global _WEATHER_CALL_COUNT
    _WEATHER_CALL_COUNT += 1

async def fetch_weather() -> dict | None:
    """Fetch current weather from OpenWeatherMap API.

    Returns dict with: description, temp, humidity, icon, city
    Returns None if not configured or on error.
    """
    global _WEATHER_CACHE, _WEATHER_CACHE_TIME

    if not WEATHER_ZIP_CODE or not WEATHER_API_KEY:
        return None

    # Check rate limit if enabled
    if WEATHER_API_LIMIT_ENABLED and not _check_weather_api_limit():
        return _WEATHER_CACHE  # Return stale cache if available

    now = time.time()
    if _WEATHER_CACHE is not None and (now - _WEATHER_CACHE_TIME) < _WEATHER_CACHE_TTL:
        return _WEATHER_CACHE

    url = "https://api.openweathermap.org/data/2.5/weather"
    params = {
        "zip": f"{WEATHER_ZIP_CODE},US",
        "appid": WEATHER_API_KEY,
        "units": WEATHER_UNITS,
    }

    try:
        async with httpx.AsyncClient(timeout=10, follow_redirects=True) as client:
            resp = await client.get(url, params=params)
            if resp.status_code == 200:
                data = resp.json()
                # Convert wind speed: m/s to mph if imperial
                wind_mph = data.get("wind", {}).get("speed", 0)
                _WEATHER_CACHE = {
                    "description": data.get("weather", [{}])[0].get("description", "").title(),
                    "temp": round(data.get("main", {}).get("temp", 0)),
                    "humidity": data.get("main", {}).get("humidity", 0),
                    "icon": data.get("weather", [{}])[0].get("icon", "01d"),
                    "city": data.get("name", ""),
                    "wind": int(wind_mph),
                }
                _WEATHER_CACHE_TIME = now
                _increment_weather_calls()
                logger.debug("Weather fetched: %s, %s°", _WEATHER_CACHE["description"], _WEATHER_CACHE["temp"])
                return _WEATHER_CACHE
            else:
                logger.warning("Weather API error: HTTP %s — %s", resp.status_code, resp.text[:200])
    except (httpx.ConnectError, httpx.TimeoutException, httpx.HTTPError) as e:
        logger.error("Weather API error: %s", e)

    return None


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup: pre-fetch photos so the first request is fast."""
    logger.info("Starting kiosk server...")
    logger.info("  IMMICH_URL=%s", IMMICH_URL)
    logger.info("  SLIDESHOW_INTERVAL=%dm", SLIDESHOW_INTERVAL_MINUTES)
    logger.info("  PAGE_REFRESH_INTERVAL=%dm", PAGE_REFRESH_INTERVAL_MINUTES)
    logger.info("  CALENDAR_REFRESH_INTERVAL=%dm", CALENDAR_REFRESH_INTERVAL_MINUTES)
    logger.info("  TRUST_PROXY=%s", TRUST_PROXY)
    logger.info("  BASE_URL=%s", BASE_URL or "(auto-detect)")
    logger.info("  CACHE_DIR=%s", CACHE_DIR)
    logger.info("  CACHE_MAX_SIZE=%d MB", MAX_CACHE_SIZE_BYTES // (1024 * 1024))
    logger.info("  LOG_LEVEL=%s", LOG_LEVEL)
    logger.info("  LOG_DIR=%s", LOG_DIR)
    asyncio.create_task(fetch_immich_photos())
    yield
    logger.info("Shutting down kiosk server...")


# Enable proxy header handling when behind a reverse proxy (Nginx, Traefik, etc.)
# root_path handles path-based routing; the middleware below removes X-Frame-Options
# for kiosk embedding when TRUST_PROXY is enabled.
root_path = os.environ.get("BASE_URL", "")
app = FastAPI(title="Kiosk", lifespan=lifespan, root_path=root_path)

if TRUST_PROXY:
    @app.middleware("http")
    async def add_security_headers(request: Request, call_next):
        """Allow iframe embedding (kiosk needs to be embedded/fullscreen)."""
        response = await call_next(request)
        # Kiosk page needs to be embeddable; remove X-Frame-Options set by FastAPI
        response.headers.pop("X-Frame-Options", None)
        return response
    logger.info("Reverse proxy mode enabled (TRUST_PROXY=true, root_path=%s)", root_path or "(none)")

app.mount("/static", StaticFiles(directory="static"), name="static")


@app.get("/", response_class=HTMLResponse)
async def kiosk_page(request: Request):
    """Serve the kiosk HTML page with split-layout slideshow + calendar."""
    photos = await fetch_immich_photos()

    slideshow_interval_ms = SLIDESHOW_INTERVAL_MINUTES * 60 * 1000
    page_refresh_ms = PAGE_REFRESH_INTERVAL_MINUTES * 60 * 1000
    calendar_refresh_seconds = CALENDAR_REFRESH_INTERVAL_MINUTES * 60

    template = env.get_template("kiosk.html")
    weather = await fetch_weather()
    calendar_url = build_calendar_url(GOOGLE_CALENDAR_URL, CALENDAR_WEEKS_AHEAD)
    html = template.render(
        photos=photos,
        slideshow_interval_ms=slideshow_interval_ms,
        page_refresh_ms=page_refresh_ms,
        calendar_refresh_seconds=calendar_refresh_seconds,
        google_calendar_url=calendar_url,
        calendar_scale=CALENDAR_SCALE,
        calendar_invert=CALENDAR_INVERT,
        weather=weather,
        weather_enabled=bool(WEATHER_ZIP_CODE and WEATHER_API_KEY),
        weather_units=WEATHER_UNITS,
    )
    return html


@app.get("/api/photos")
async def api_photos():
    """JSON API returning current photo URLs — for debugging or external use."""
    photos = await fetch_immich_photos()
    return Response(
        content=json.dumps({"photos": photos, "count": len(photos)}),
        media_type="application/json",
    )


@app.get("/photo/{asset_id}", response_class=HTMLResponse)
async def photo_proxy(asset_id: str, request: Request):
    """Serve a cached thumbnail locally (avoids CORS issues when loading from Immich)."""
    cache_path = _asset_cache_path(asset_id)

    if cache_path.exists():
        # Serve cached file
        content = cache_path.read_bytes()
        return Response(content=content, media_type="image/jpeg")

    # Not cached — try to fetch it now (one-time fetch)
    api_base = f"{IMMICH_URL}/api"
    auth_params = {"key": IMMICH_SHARED_LINK_KEY}
    try:
        async with httpx.AsyncClient(timeout=15, follow_redirects=True) as client:
            resp = await client.get(f"{api_base}/assets/{asset_id}/thumbnail", params=auth_params)
            if resp.status_code == 200:
                cache_path.write_bytes(resp.content)
                _cache_cleanup()
                return Response(content=resp.content, media_type="image/jpeg")
            logger.warning("Failed to fetch thumbnail for %s: HTTP %s", asset_id, resp.status_code)
    except (httpx.ConnectError, httpx.TimeoutException, httpx.HTTPError) as e:
        logger.error("Error fetching thumbnail %s: %s", asset_id, e)

    # Return placeholder 1x1 transparent PNG
    placeholder = base64.b64decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
    )
    return Response(content=placeholder, media_type="image/png")


@app.get("/health")
async def health():
    """Simple health check endpoint."""
    return {"status": "ok"}


@app.get("/favicon.ico")
async def favicon():
    """Serve a blank favicon to avoid 404s."""
    return Response(content="", media_type="image/x-icon")


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host=os.environ.get("WEB_HOST", "0.0.0.0"), port=int(os.environ.get("WEB_PORT", "8080")))  # nosec B104
