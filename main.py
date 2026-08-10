"""
Kiosk Web Server

Serves a full-screen kiosk page with:
  - Left side: slideshow of photos from an Immich shared album
  - Right side: embedded Google Calendar

Photos are fetched from the Immich API via the shared link key (no user auth needed).
The calendar is embedded via an iframe to the Google Calendar public embed URL.
"""

import asyncio
import json
import logging
import os
import time

from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, Request, Response
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from jinja2 import Environment, FileSystemLoader, select_autoescape

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger(__name__)

# --- Configuration from environment ---
IMMICH_URL = os.environ.get("IMMICH_URL", "https://photos.yourdomain.com").rstrip("/")
IMMICH_SHARED_LINK_KEY = os.environ.get("IMMICH_SHARED_LINK_KEY", "")
IMMICH_THUMB_SIZE = os.environ.get("IMMICH_THUMB_SIZE", "large")
SLIDESHOW_INTERVAL_MINUTES = int(os.environ.get("SLIDESHOW_INTERVAL_MINUTES", "15"))
GOOGLE_CALENDAR_URL = os.environ.get(
    "GOOGLE_CALENDAR_URL",
    "https://calendar.google.com/calendar/embed?src=d1hts4hbba10stq9eg2r0r52o8%40group.calendar.google.com&ctz=America%2FChicago",
)
CALENDAR_REFRESH_INTERVAL_MINUTES = int(os.environ.get("CALENDAR_REFRESH_INTERVAL_MINUTES", "30"))
PAGE_REFRESH_INTERVAL_MINUTES = int(os.environ.get("PAGE_REFRESH_INTERVAL_MINUTES", "30"))
TRUST_PROXY = os.environ.get("TRUST_PROXY", "false").lower() in ("true", "1", "yes")
BASE_URL = os.environ.get("BASE_URL", "").rstrip("/")

# --- Jinja2 environment for inline HTML rendering ---
env = Environment(
    loader=FileSystemLoader("templates"),
    autoescape=select_autoescape(["html"]),
    auto_reload=True,
)

# Cache for photo URLs — refreshed on each API call
_cached_photos: list[str] | None = None
_last_fetch: float = 0
_cache_ttl = 60  # seconds


async def _fetch_album_assets(
    client: httpx.AsyncClient,
    api_base: str,
    auth_params: dict,
    album_id: str,
) -> list[str]:
    """
    Fetch all asset thumbnail URLs from an Immich album via search/metadata.

    Uses POST /api/search/metadata with albumIds filter to get all assets.
    Handles pagination to fetch all assets (not just the first page).
    """
    photo_urls = []
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
        assets = data.get("assets", {})
        items = assets.get("items", [])
        total = assets.get("total", 0)

        for asset in items:
            asset_id = asset.get("id")
            if asset_id:
                thumb_url = f"{api_base}/assets/{asset_id}/thumbnail?key={IMMICH_SHARED_LINK_KEY}&size={IMMICH_THUMB_SIZE}"
                photo_urls.append(thumb_url)

        # Stop if we got fewer items than the page size, or no items at all
        if len(items) < page_size:
            break
        page += 1

    return photo_urls


async def fetch_immich_photos() -> list[str]:
    """
    Fetch all asset thumbnail URLs from the Immich shared link.

    Flow:
      1. GET /api/shared-links/me?key={key} — resolves the shared link key to
         a SharedLinkResponseDto containing the album ID and metadata.
      2. POST /api/search/metadata?key={key} with albumIds filter — fetches
         all assets in the album (paginated).
      3. Build thumbnail URLs: /api/assets/{assetId}/thumbnail?key={key}&size={size}

    The shared link key acts as auth for these endpoints — no API key needed.
    """
    global _cached_photos, _last_fetch

    now = time.time()
    if _cached_photos is not None and (now - _last_fetch) < _cache_ttl:
        return _cached_photos

    if not IMMICH_SHARED_LINK_KEY:
        logger.warning("IMMICH_SHARED_LINK_KEY is not set; photo list will be empty")
        _cached_photos = []
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
                _last_fetch = now
                return _cached_photos

            link_data = resp.json()
            album = link_data.get("album")

            # If this is an album-type shared link, get assets via search/metadata
            # If the shared link already has assets in the response, use those
            assets = link_data.get("assets", [])

            if not assets and album and album.get("id"):
                # Fallback: search for assets in the album via search/metadata endpoint
                album_id = album["id"]
                logger.info("Fetching assets for album %s via search/metadata", album_id)
                photo_urls = await _fetch_album_assets(client, api_base, auth_params, album_id)
                logger.info("Fetched %d photos from Immich album", len(photo_urls))
                _cached_photos = photo_urls
                _last_fetch = now
                return _cached_photos

            if not assets:
                logger.warning("No assets found in shared link")
                _cached_photos = []
                _last_fetch = now
                return _cached_photos

            # Build thumbnail URLs from assets returned directly in shared link
            photo_urls = []
            for asset in assets:
                asset_id = asset.get("id")
                if asset_id:
                    thumb_url = f"{api_base}/assets/{asset_id}/thumbnail?key={IMMICH_SHARED_LINK_KEY}&size={IMMICH_THUMB_SIZE}"
                    photo_urls.append(thumb_url)

            logger.info("Fetched %d photos from Immich shared link", len(photo_urls))
            _cached_photos = photo_urls
            _last_fetch = now
            return _cached_photos
    except (httpx.ConnectError, httpx.TimeoutException, httpx.HTTPError) as e:
        logger.error("Error fetching photos from Immich: %s", e)
        _cached_photos = []
        _last_fetch = now
        return _cached_photos


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
    asyncio.create_task(fetch_immich_photos())
    yield
    logger.info("Shutting down kiosk server...")


# Enable proxy header handling when behind a reverse proxy (Nginx, Traefik, etc.)
# root_path handles path-based routing; the middleware below sets the correct
# base URL when behind a proxy that forwards to a subpath.
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
    html = template.render(
        photos=photos,
        slideshow_interval_ms=slideshow_interval_ms,
        page_refresh_ms=page_refresh_ms,
        calendar_refresh_seconds=calendar_refresh_seconds,
        google_calendar_url=GOOGLE_CALENDAR_URL,
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

    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("WEB_PORT", "8080")))
