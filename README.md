# Kiosk

A Raspberry Pi kiosk application that displays a split-screen layout:
- **Left side**: Slideshow of photos from an Immich shared album
- **Right side**: Embedded Google Calendar

Photos rotate at a configurable interval, and the calendar refreshes automatically. The entire page reloads periodically to pick up new photos.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Raspberry Pi (Kiosk Client)                             │
│  Chromium in kiosk mode → http://<server>:8080           │
│  ┌─────────────────┬─────────────────┐                  │
│  │  Photo Slideshow│  Google Calendar │                  │
│  │  (Immich API)   │  (Embedded iframe)│                  │
│  └─────────────────┴─────────────────┘                  │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  Docker Host (Web Server)                                  │
│  - FastAPI app fetches photos via Immich shared link API  │
│  - Serves the kiosk HTML page                             │
│  - Calendar embedded directly via Google Calendar embed   │
└─────────────────────────────────────────────────────────┘
```

## Setup

### 1. Configure the `.env` file

Copy the example and fill in your details:

```bash
cp .env.example .env
```

Edit `.env` with your configuration:

```bash
IMMICH_URL=https://photos.yourdomain.com      # Your Immich instance
IMMICH_SHARED_LINK_KEY=your-shared-link-key   # From your Immich shared link URL
GOOGLE_CALENDAR_URL=https://calendar.google.com/calendar/embed?src=...  # Public calendar embed URL
SLIDESHOW_INTERVAL_MINUTES=15                # Photo change interval
PAGE_REFRESH_INTERVAL_MINUTES=30             # Full page reload interval
CALENDAR_REFRESH_INTERVAL_MINUTES=30         # Calendar iframe reload interval
WEB_PORT=8080                                 # Port the web server listens on
IMMICH_THUMB_SIZE=large                       # Thumbnail size from Immich
```

### 2. Start the web server

First, create the data directories on the Docker host:

```bash
sudo mkdir -p /root/docker/kiosk/data /root/docker/kiosk/cache
```

Then start the server:

```bash
docker compose up -d
```

The kiosk will be available at `http://<your-server-ip>:8080`.

### Optional: Run behind a reverse proxy (Nginx)

If you want to serve the kiosk over HTTPS or via a custom domain, set up Nginx as a reverse proxy.

1. Set `TRUST_PROXY=true` and `BASE_URL` in `.env`:

```bash
TRUST_PROXY=true
BASE_URL=https://kiosk.yourdomain.com
```

2. Example Nginx config (`/etc/nginx/sites-available/kiosk`):

```nginx
server {
    listen 443 ssl http2;
    server_name kiosk.yourdomain.com;

    # SSL (use your own certs — Let's Encrypt, etc.)
    ssl_certificate /etc/ssl/certs/kiosk.crt;
    ssl_certificate_key /etc/ssl/private/kiosk.key;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

3. Enable and reload Nginx:

```bash
sudo ln -s /etc/nginx/sites-available/kiosk /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

4. Restart the kiosk server to pick up the new env settings:

```bash
docker compose up -d --build
```

Then point your Pi's `KIOSK_URL` to `https://kiosk.yourdomain.com`.

### 3. Find your Immich shared link key

1. In Immich, open the album you want to display
2. Click the **Share** icon → **Create a link**
3. Copy the shared link — it looks like:
   ```
   https://photos.yourdomain.com/share/abc123DEF456...
   ```
4. The key is everything after `/share/` — paste it in `.env` as `IMMICH_SHARED_LINK_KEY`

### 4. Set up the Raspberry Pi kiosk client

Run this on your Raspberry Pi (Raspberry Pi OS with desktop recommended):

```bash
curl -s https://raw.githubusercontent.com/wickedyoda/kiosk/main/kiosk-client-setup.sh | KIOSK_URL=http://<your-server-ip>:8080 sudo bash
```

Then reboot:

```bash
sudo reboot
```

### 5. Make your Google Calendar public

1. Go to [Google Calendar](https://calendar.google.com)
2. In the left panel, find your calendar → click the **three dots** → **Settings and sharing**
3. Under **Access permissions**, check **Make available to public**
4. Under **Integrate calendar**, copy the **Embed code** URL and paste it into `GOOGLE_CALENDAR_URL` in `.env`

## `.env` Variables Reference

| Variable | Description | Default |
|----------|-------------|---------|
| `IMMICH_URL` | Your Immich server URL | `https://photos.yourdomain.com` |
| `IMMICH_SHARED_LINK_KEY` | The shared link key from your Immich album | _(required)_ |
| `IMMICH_THUMB_SIZE` | Thumbnail size: `original`, `large`, `medium`, `small` | `large` |
| `GOOGLE_CALENDAR_URL` | Google Calendar embed URL | _(required)_ |
| `SLIDESHOW_INTERVAL_MINUTES` | How often photos change | `15` |
| `PAGE_REFRESH_INTERVAL_MINUTES` | How often the full page reloads | `30` |
| `CALENDAR_REFRESH_INTERVAL_MINUTES` | How often the calendar iframe reloads | `30` |
| `WEB_PORT` | Port for the web server | `8080` |
| `IMMICH_THUMB_SIZE` | Thumbnail size: `original`, `large`, `medium`, `small` | `large` |
| `TRUST_PROXY` | Enable proxy header handling (for Nginx/Traefik) | `false` |
| `BASE_URL` | Public-facing URL when behind reverse proxy | _(empty)_ |
| `DATA_PATH` | Data directory inside container (mapped to host via docker-compose) | `/app/data` |
| `CACHE_MAX_SIZE_MB` | Max local thumbnail cache size | `1024` |
| `CACHE_MAX_AGE_SECONDS` | Cache entry TTL before eviction | `86400` (24h) |

## Files

```
.
├── .env                 # Environment configuration (not in git)
├── .env.example         # Example environment file
├── main.py              # FastAPI web server
├── Dockerfile           # Docker image for dev
├── Dockerfile.prod      # Docker image for production
├── docker-compose.yml   # Docker Compose configuration
├── requirements.txt     # Python dependencies
├── templates/
│   └── kiosk.html       # Kiosk page HTML template
├── static/              # Static assets (placeholder.jpg, etc.)
├── kiosk-client-setup.sh # Raspberry Pi setup script
└── README.md            # This file
```

### How It Works

### Photo Slideshow (Left)
1. On page load, the server calls `GET /api/shared-links/me?key={key}` to the Immich API
2. This returns all assets in the shared link, including their IDs
3. Thumbnails are **downloaded and cached locally** on the Docker host (max 1GB) — the browser never contacts Immich directly (avoids CORS issues)
4. Each image is served via a local proxy endpoint: `GET /photo/{assetId}`
5. The slideshow uses crossfade transitions and auto-advances every `SLIDESHOW_INTERVAL_MINUTES`
6. The page auto-reloads every `PAGE_REFRESH_INTERVAL_MINUTES` to pick up new photos
7. Cache management:
   - LRU eviction when total cache exceeds `CACHE_MAX_SIZE_MB` (default 1024 MB)
   - Stale entries older than `CACHE_MAX_AGE_SECONDS` (default 86400 = 24h) are removed
   - Entries for assets no longer in the album are deleted on each photo fetch

### Google Calendar (Right)
- The calendar is embedded via an `<iframe>` in **Schedule (AGENDA) view**
- Only events within a **2-week window** are displayed (via the `dates` URL parameter)
- The date range is recalculated on each calendar refresh to keep the window current
- It auto-refreshes every `CALENDAR_REFRESH_INTERVAL_MINUTES` by reloading the iframe with an updated URL
- No Google API authentication is needed — just a public calendar

## Troubleshooting

### Photos not showing
- Verify `IMMICH_SHARED_LINK_KEY` is correct (everything after `/share/` in the URL)
- Check that the album is shared publicly in Immich
- Verify `IMMICH_URL` is correct (no trailing slash)
- Run `docker compose logs kiosk` to check server logs

### Calendar not showing
- Verify the Google Calendar is set to **public**
- Check that `GOOGLE_CALENDAR_URL` is the correct embed URL (not the share URL)
- The embed URL starts with `https://calendar.google.com/calendar/embed?src=...`

### Kiosk not starting on Pi
- Ensure the Pi boots to desktop: `sudo raspi-config` → **Boot / Auto Login** → **Desktop Autologin**
- Check Chromium installed: `chromium-browser --version`
- Run the start script manually: `/home/pi/kiosk-start.sh`

## Security Notes

- The Immich shared link key is sent to the browser only for thumbnail image requests
- The web server acts as a proxy only for the photo list API call (the key never touches the browser for that)
- Consider restricting access to the kiosk server with a reverse proxy or firewall
- All communications should be over HTTPS in production

## License

MIT
