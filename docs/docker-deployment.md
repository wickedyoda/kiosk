# Docker Deployment Guide

## Overview

The Kiosk application runs as a Docker container using `docker compose`. It can be hosted either on the same machine as the kiosk display (client-hosted) or on a separate server (server-hosted).

## Quick Start

```bash
git clone https://github.com/wickedyoda/kiosk.git
cd kiosk
cp .env.example .env
# Edit .env with your Immich, Google Calendar, and server settings
docker compose up -d --build
```

The kiosk web interface will be available at `http://<your-host-ip>:8080`.

## Docker Compose

The `docker-compose.yml` file:

```yaml
services:
  app:
    build: .
    ports:
      - "${WEB_PORT:-8080}:8080"
    env_file:
      - .env
    volumes:
      - kiosk-data:/app/data
      - kiosk-logs:/app/logs
    restart: unless-stopped

volumes:
  kiosk-data:
  kiosk-logs:
```

### Volumes

| Volume | Maps to | Purpose |
|--------|---------|---------|
| `kiosk-data` | `/app/data` | Photo thumbnail cache |
| `kiosk-logs` | `/app/logs` | Application log files |

## Hosting Options

### Option 1: Client-Hosted (Single Machine)

Run both the Docker server and the kiosk browser on the same machine:

```bash
# On the client
docker compose up -d --build

# Point the kiosk client to localhost
curl -s https://raw.githubusercontent.com/wickedyoda/kiosk/main/kiosk-client-setup.sh \
  | KIOSK_URL=http://localhost:8080 sudo bash
```

### Option 2: Server-Hosted (Separate Server)

Deploy on a dedicated server and point kiosk clients at it:

```bash
# On the server
docker compose up -d --build

# On each kiosk client
curl -s https://raw.githubusercontent.com/wickedyoda/kiosk/main/kiosk-client-setup.sh \
  | KIOSK_URL=http://<server-ip>:8080 sudo bash
```

## Docker Commands

```bash
# Start
docker compose up -d --build

# Rebuild (after code changes)
docker compose up -d --build

# Stop
docker compose down

# View logs
docker compose logs -f

# Restart
docker compose restart

# Run a command inside the container
docker compose exec app bash

# View file logs
docker exec -it kiosk-app-1 cat /app/logs/kiosk.log
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `WEB_PORT` | Host port to expose | `8080` |
| `WEB_HOST` | Bind address | `0.0.0.0` |
| `IMMICH_URL` | Immich server URL | — |
| `IMMICH_SHARED_LINK_KEY` | Immich shared link key | — |
| `GOOGLE_CALENDAR_URL` | Calendar embed URL | — |
| `CALENDAR_SCALE` | Calendar text scale | `2.0` |
| `CALENDAR_INVERT` | Invert calendar colors | `true` |
| `CACHE_MAX_SIZE_MB` | Max thumbnail cache | `1024` |
| `CACHE_MAX_AGE_SECONDS` | Cache TTL | `86400` |
| `LOG_LEVEL` | Log verbosity | `DEBUG` |
| `LOG_DIR` | Log directory | `/app/logs` |
| `SLIDESHOW_INTERVAL_MINUTES` | Photo change interval | `15` |
| `PAGE_REFRESH_INTERVAL_MINUTES` | Full page reload interval | `30` |
| `CALENDAR_REFRESH_INTERVAL_MINUTES` | Calendar refresh interval | `30` |
| `TRUST_PROXY` | Enable proxy headers | `false` |
| `BASE_URL` | Public URL for reverse proxy | _(empty)_ |

## Health Check

```bash
curl http://localhost:8080/health
# Expected: {"status":"ok"}
```

## Production Deployment

For production, use the multi-stage `Dockerfile.prod`:

```bash
docker build -f Dockerfile.prod -t kiosk:latest .
docker run -d --name kiosk-app -p 8080:8080 --env-file .env kiosk:latest
```

Or with the compose file:

```bash
docker compose -f docker-compose.yml up -d
```
