# Troubleshooting

Common issues and solutions for the Kiosk application.

## Table of Contents

- [Photos Not Showing](#photos-not-showing)
- [Calendar Not Showing](#calendar-not-showing)
- [Kiosk Not Starting on Client](#kiosk-not-starting-on-client)
- [Docker Issues](#docker-issues)
- [Checking Logs](#checking-logs)
- [Reconfiguring a Client](#reconfiguring-a-client)

---

## Photos Not Showing

### 1. Verify Immich Shared Link Key

The shared link key is the string after `/share/` in your Immich share URL:

```
https://photos.example.com/share/abc123DEF456...
                            ^^^^^^^^^^^^^^^^^^
                            This is the key
```

Check it's set correctly in `.env`:
```bash
grep IMMICH_SHARED_LINK_KEY .env
```

### 2. Verify Album is Public

In Immich:
1. Go to the album
2. Click **Share** → **Create link** (if not already created)
3. Ensure the link is enabled (not expired)

### 3. Check Immich URL

```bash
grep IMMICH_URL .env
```

Make sure there's no trailing slash. It should be `https://photos.example.com`, not `https://photos.example.com/`.

### 4. Check Server Logs

```bash
docker compose logs -f
```

Look for errors like "Failed to fetch shared link" or "No assets found".

---

## Calendar Not Showing

### 1. Verify Calendar is Public

In Google Calendar:
1. Go to [Google Calendar](https://calendar.google.com)
2. Left panel → your calendar → three dots → **Settings and sharing**
3. Under **Access permissions**, ensure "Make available to public" is checked
4. Under **Integrate calendar**, copy the **Embed code** URL

### 2. Verify Embed URL Format

The URL in `.env` should look like:
```
https://calendar.google.com/calendar/embed?src=...@group.calendar.google.com&ctz=America/Chicago&mode=AGENDA&...
```

### 3. Check Date Range Filter

The calendar shows events within a 2-week window. If there are no events in the next 2 weeks, the calendar will appear empty.

### 4. Verify Calendar Parameters

Ensure these parameters are in the URL:
- `mode=AGENDA` — schedule/list view
- `showAdd=0` — hides the "Add to Calendar" button (not needed for kiosk)
- `showDate=0` — hides date selector
- `showNav=0` — hides navigation buttons

---

## Kiosk Not Starting on Client

### 1. Check Boot Target

```bash
systemctl get-default
```

Should return `graphical.target`. If not:
```bash
sudo systemctl set-default graphical.target
```

### 2. Check Xorg is Running

```bash
ps aux | grep Xorg
```

If not running, check:
```bash
systemctl status kiosk.service
journalctl -u kiosk.service -n 50
```

### 3. Check Chromium Installation

```bash
chromium --version
```

### 4. Run Start Script Manually

```bash
/root/kiosk-start.sh
```

This will show any errors from Xorg or Chromium.

### 5. Check X Session

If Chromium fails, try starting X manually:
```bash
startx /root/.xinitrc -- -nocursor -nolisten tcp -noreset
```

---

## Docker Issues

### Container Won't Start

```bash
# Check logs
docker compose logs

# Rebuild from scratch
docker compose down -v
docker compose up -d --build
```

### Port Already in Use

Change `WEB_PORT` in `.env`:
```bash
WEB_PORT=8081
```

Then restart:
```bash
docker compose up -d --build
```

### Permission Denied on Docker Socket

```bash
sudo usermod -aG docker $USER
# Then log out and back in
```

---

## Checking Logs

### Container Logs (stdout)

```bash
docker compose logs -f
```

### File Logs (debug-level)

The app writes detailed logs to `/app/logs/kiosk.log` inside the container:

```bash
docker exec -it kiosk-app-1 cat /app/logs/kiosk.log
```

### View on Host Machine

If using the docker-compose volumes:
```bash
# Find the volume mount point
docker volume inspect kiosk_kiosk-logs
```

### Change Log Level

Edit `.env`:
```bash
LOG_LEVEL=INFO
# Options: DEBUG, INFO, WARNING, ERROR, CRITICAL
```

Then restart:
```bash
docker compose up -d --build
```

---

## Reconfiguring a Client

### Change the Kiosk URL

Re-run the setup script with the new URL:

```bash
KIOSK_URL=http://<new-server>:<port> sudo ./kiosk-client-setup.sh
sudo reboot
```

### Change Calendar Scale

Edit `/root/kiosk-start.sh` and update the `--force-device-scale-factor` value:

```bash
sudo sed -i 's/--force-device-scale-factor=.*--force-device-scale-factor=1.5/' /root/kiosk-start.sh
sudo systemctl restart kiosk.service
```

### Remove Kiosk Completely

```bash
KIOSK_ACTION=remove sudo ./kiosk-client-setup.sh
```

This stops the service, removes all config files, and restores standard boot behavior.
