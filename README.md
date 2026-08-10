# Kiosk

A **Docker-hosted kiosk web application** that displays a split-screen layout:
- **Left side**: Slideshow of photos from an Immich shared album
- **Right side**: Embedded Google Calendar (Schedule/AGENDA view)

Photos rotate at a configurable interval, and the calendar refreshes automatically. The entire page reloads periodically to pick up new photos.

The server runs in Docker (using `docker compose`) and can be hosted either **on the client machine itself** or on a **separate server** on the network. Clients run a lightweight Chromium kiosk browser pointing at the server URL.

---

## Table of Contents

1. [Architecture](#architecture)
2. [Prerequisites](#prerequisites)
3. [Quick Start](#quick-start)
4. [Detailed Setup](#detailed-setup)
   - [Configure `.env`](#configure-env)
   - [Start the Web Server](#start-the-web-server)
   - [Optional: Reverse Proxy (Nginx)](#optional-reverse-proxy-nginx)
   - [Find Your Immich Shared Link Key](#find-your-immich-shared-link-key)
   - [Set Up the Kiosk Client](#set-up-the-kiosk-client)
   - [Make Your Google Calendar Public](#make-your-google-calendar-public)
5. [Docker Deployment](#docker-deployment)
   - [Hosting on the Client (Single-Machine)](#hosting-on-the-client-single-machine)
   - [Hosting on a Separate Server](#hosting-on-a-separate-server)
6. [`.env` Variables Reference](#env-variables-reference)
7. [File Layout](#file-layout)
8. [How It Works](#how-it-works)
9. [Client Script Usage](#client-script-usage)
10. [Troubleshooting](#troubleshooting)
11. [Security Notes](#security-notes)
12. [License](#license)

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Kiosk Client (Debian/Ubuntu, no GUI)                   │
│  Chromium in kiosk mode → http://<server>:8080           │
│  ┌─────────────────┬─────────────────┐                  │
│  │  Photo Slideshow│  Google Calendar │                  │
│  │  (Immich API)   │  (Embedded iframe)│                  │
│  └─────────────────┴─────────────────┘                  │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  Docker Host (Web Server)                                │
│  - FastAPI app fetches photos via Immich shared link API │
│  - Serves the kiosk HTML page                            │
│  - Calendar embedded directly via Google Calendar embed  │
│  - Local thumbnail caching with LRU eviction             │
│  - Runs as: docker compose up -d                         │
└─────────────────────────────────────────────────────────┘
```

### Hosting Options

| Option | Where the Docker server runs | Where the kiosk browser runs |
|--------|------------------------------|------------------------------|
| **Client-hosted** | On the same Debian/Ubuntu machine as the kiosk display | Same machine |
| **Server-hosted** | On a dedicated server (e.g. your Proxmox box, NAS, docker1) | Separate thin client or kiosk machine |

---

## Prerequisites

Before you begin, ensure you have:

1. **Immich instance** with a public/shared album
2. **Google Calendar** that can be set to public
3. For the **kiosk client**: a Debian 12/13 or Ubuntu 22.04+ machine with no GUI installed
4. For the **Docker host**: Docker and Docker Compose installed

---

## Quick Start

```bash
# 1. Clone and configure
git clone https://github.com/wickedyoda/kiosk.git
cd kiosk
cp .env.example .env
# Edit .env with your Immich key and Google Calendar URL
nano .env

# 2. Start the server
docker compose up -d --build

# 3. On a client machine, run the kiosk setup
curl -s https://raw.githubusercontent.com/wickedyoda/kiosk/main/kiosk-client-setup.sh | sudo KIOSK_URL=http://<server-ip>:8080 KIOSK_ACTION=install bash
sudo reboot
```

---

## Detailed Setup

### Configure `.env`

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
CALENDAR_SCALE=2.0                            # Scale calendar text (1.0 = normal, 2.0 = 2x)
CALENDAR_INVERT=true                         # Invert calendar colors for kiosk display
```

### Start the Web Server

The data and logs are persisted using Docker named volumes (no manual directory creation needed):

```bash
docker compose up -d --build
```

The kiosk will be available at `http://<your-server-ip>:8080`.

### Optional: Reverse Proxy (Nginx)

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

Then point your client's `KIOSK_URL` to `https://kiosk.yourdomain.com`.

### Find Your Immich Shared Link Key

1. In Immich, open the album you want to display
2. Click the **Share** icon → **Create a link**
3. Copy the shared link — it looks like:
   ```
   https://photos.yourdomain.com/share/abc123DEF456...
   ```
4. The key is everything after `/share/` — paste it in `.env` as `IMMICH_SHARED_LINK_KEY`

### Set Up the Kiosk Client

Run the setup script on your Debian 12/13 headless client:

```bash
curl -s https://raw.githubusercontent.com/wickedyoda/kiosk/main/kiosk-client-setup.sh | sudo KIOSK_URL=http://<your-server-ip>:8080 KIOSK_ACTION=install bash
```

Then reboot:

```bash
sudo reboot
```

### Make Your Google Calendar Public

1. Go to [Google Calendar](https://calendar.google.com)
2. In the left panel, find your calendar → click the **three dots** → **Settings and sharing**
3. Under **Access permissions**, check **Make available to public**
4. Under **Integrate calendar**, copy the **Embed code** URL and paste it into `GOOGLE_CALENDAR_URL` in `.env`

---

## Docker Deployment

### Hosting on the Client (Single-Machine)

Install Docker and Docker Compose on the same machine that will serve as the kiosk display:

```bash
# On the client machine
sudo apt-get update
sudo apt-get install -y docker.io docker-compose
sudo usermod -aG docker $USER

# Clone repo
git clone https://github.com/wickedyoda/kiosk.git
cd kiosk
cp .env.example .env
# ...configure .env...
docker compose up -d --build

# Then run the kiosk client setup pointing to localhost
curl -s https://raw.githubusercontent.com/wickedyoda/kiosk/main/kiosk-client-setup.sh | sudo KIOSK_URL=http://localhost:8080 KIOSK_ACTION=install bash
sudo reboot
```

### Hosting on a Separate Server

Deploy on a dedicated Docker host and point kiosk clients at it:

```bash
# On the server (e.g. docker1.tail99133.ts.net)
git clone https://github.com/wickedyoda/kiosk.git
cd kiosk
cp .env.example .env
# ...configure .env...
docker compose up -d --build

# On each kiosk client
curl -s https://raw.githubusercontent.com/wickedyoda/kiosk/main/kiosk-client-setup.sh | sudo KIOSK_URL=http://<server-ip>:8080 KIOSK_ACTION=install bash
sudo reboot
```

---

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
| `CALENDAR_SCALE` | Scale factor for calendar content (e.g. 1.5, 2.0) | `2.0` |
| `CALENDAR_INVERT` | Invert calendar colors for kiosk display | `true` |
| `WEATHER_ZIP_CODE` | US ZIP code for weather overlay (empty = disabled) | _(empty)_ |
| `WEATHER_API_KEY` | OpenWeatherMap API key (if WEATHER_ZIP_CODE is set) | _(empty)_ |
| `WEATHER_UNITS` | `imperial` (°F) or `metric` (°C) | `imperial` |
| `WEATHER_REFRESH_MINUTES` | Weather refresh interval (default 240, min 120) | `240` |
| `WEATHER_API_LIMIT_ENABLED` | Enable daily call limit enforcement | `true` |
| `WEATHER_API_DAILY_LIMIT` | Hard cap on weather API calls per 24h | `999` |
| `WEB_PORT` | Port for the web server | `8080` |
| `WEB_HOST` | Bind address for the web server | `0.0.0.0` |
| `TRUST_PROXY` | Enable proxy header handling (for Nginx/Traefik) | `false` |
| `BASE_URL` | Public-facing URL when behind reverse proxy | _(empty)_ |
| `DATA_PATH` | Data directory inside container | `/app/data` |
| `CACHE_MAX_SIZE_MB` | Max local thumbnail cache size | `1024` |
| `CACHE_MAX_AGE_SECONDS` | Cache entry TTL before eviction | `86400` (24h) |
| `LOG_LEVEL` | Logging level: `DEBUG`, `INFO`, `WARNING`, `ERROR`, `CRITICAL` | `DEBUG` |
| `LOG_DIR` | Directory for log files | `/app/logs` |

---

## File Layout

```
├── .env                 # Environment configuration (not in git)
├── .env.example         # Example environment file
├── .gitignore
├── .dockerignore
├── main.py              # FastAPI web server
├── Dockerfile           # Docker image (dev)
├── Dockerfile.prod      # Docker image (production)
├── docker-compose.yml   # Docker Compose configuration
├── requirements.txt     # Python dependencies
├── Makefile             # Convenience targets (build, up, down, logs, restart)
├── templates/
│   └── kiosk.html       # Kiosk page HTML template
├── static/              # Static assets
└── kiosk-client-setup.sh  # Debian/Ubuntu kiosk client setup script
```

---

## How It Works

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
- The "Add to Calendar" button is **disabled** (`showAdd=0`) — kiosk displays have no input devices
- Calendar text can be scaled via `CALENDAR_SCALE` and colors can be inverted via `CALENDAR_INVERT`
- No Google API authentication is needed — just a public calendar

---

## Client Script Usage

The `kiosk-client-setup.sh` script offers **three actions** via an interactive prompt:

```bash
curl -s https://raw.githubusercontent.com/wickedyoda/kiosk/main/kiosk-client-setup.sh | sudo bash
```

You'll see:
```
What would you like to do?
  1) Install a NEW kiosk (fails if already installed)
  2) UPDATE existing kiosk settings (requires existing installation)
  3) Uninstall and remove the kiosk
```

### Non-interactive mode

Skip the prompt by passing `KIOSK_ACTION` as an env var:

```bash
# Install new kiosk
curl -s https://raw.githubusercontent.com/wickedyoda/kiosk/main/kiosk-client-setup.sh \
  | sudo KIOSK_URL=http://<server>:8080 KIOSK_ACTION=install bash

# Update existing kiosk
curl -s https://raw.githubusercontent.com/wickedyoda/kiosk/main/kiosk-client-setup.sh \
  | sudo KIOSK_URL=http://<server>:8080 KIOSK_ACTION=update bash

# Remove kiosk
curl -s https://raw.githubusercontent.com/wickedyoda/kiosk/main/kiosk-client-setup.sh \
  | sudo KIOSK_ACTION=remove bash
```

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `KIOSK_URL` | Kiosk server URL (required for setup) | _(none)_ |
| `KIOSK_SCALE` | Chromium device scale factor | `1.0` |
| `KIOSK_INVERT` | Invert calendar colors | `false` |
| `KIOSK_USER` | User to run as | `root` |
| `KIOSK_SLIDESHOW_INTERVAL` | Photo shuffle interval (min) | `15` |
| `KIOSK_ACTION` | `install`, `update`, `remove` | _(interactive prompt)_ |

---

## Troubleshooting

### Photos not showing
- Verify `IMMICH_SHARED_LINK_KEY` is correct (everything after `/share/` in the URL)
- Check that the album is shared publicly in Immich
- Verify `IMMICH_URL` is correct (no trailing slash)
- Run `docker compose logs` to check server logs

### Calendar not showing
- Verify the Google Calendar is set to **public**
- Check that `GOOGLE_CALENDAR_URL` is the correct embed URL (not the share URL)
- The embed URL starts with `https://calendar.google.com/calendar/embed?src=...`

### Kiosk not starting on client
- Ensure the host is booted to `multi-user.target`: `systemctl get-default` should return `multi-user.target`
- Check Xorg is running: `ps aux | grep Xorg`
- Check Chromium is installed: `chromium --version`
- Run the start script manually: `/usr/local/bin/start-kiosk-x`
- Check the kiosk log: `journalctl -u kiosk.service -n 50`

### Black screen
- Ensure the display is connected and powered on before boot
- Check `/root/kiosk-start.sh` for correct URL
- Verify the kiosk server is reachable from the client: `curl -s http://<server>:8080/health`

### Checking logs
Logs are written to `/app/logs/kiosk.log` inside the container (mapped to a Docker volume). To view:

```bash
docker compose logs -f                          # Stream container logs (stdout)
docker exec -it kiosk-app-1 cat /app/logs/kiosk.log  # View file logs
```

To change log verbosity, set `LOG_LEVEL` in `.env` to `DEBUG`, `INFO`, `WARNING`, `ERROR`, or `CRITICAL`.

### Reconfiguring a client
To change the kiosk URL or settings on an existing client:

```bash
sudo KIOSK_URL=http://<new-server>:<port> KIOSK_ACTION=update bash kiosk-client-setup.sh
sudo reboot
```

---

## Security Notes

- The Immich shared link key is used by the server to fetch photos — it is **not** sent to the browser for API calls. Only thumbnail image requests use the key (proxied through `/photo/{id}`)
- The web server acts as a proxy for the photo list API call — the browser never sees the Immich API key for listing
- Consider restricting access to the kiosk server with a reverse proxy (HTTPS) or firewall
- All communications should be over HTTPS in production
- The kiosk client runs Chromium in `--no-web-security` mode — only deploy on trusted networks

---

## License

MIT
