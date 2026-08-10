# Client Setup Guide

This guide covers setting up a Debian or Ubuntu headless machine as a kiosk client that displays the Kiosk web application full-screen on boot.

## Prerequisites

- Debian 12 (Bookworm) or Debian 13 (Trixie), or Ubuntu 22.04+
- No GUI installed (headless)
- Network access to reach the kiosk web server
- Root/sudo privileges

## Quick Setup

```bash
curl -s https://raw.githubusercontent.com/wickedyoda/kiosk/main/kiosk-client-setup.sh | KIOSK_URL=http://<server-ip>:8080 sudo bash
sudo reboot
```

## What the Script Does

1. **Installs packages**: Xorg, Chromium, xinit, unclutter
2. **Creates `/root/kiosk-start.sh`**: Launches Chromium in kiosk mode
3. **Configures X session files**: `/root/.xinitrc` and `/root/.xsession`
4. **Sets boot target**: `graphical.target`
5. **Creates systemd service**: `/etc/systemd/system/kiosk.service`
6. **Configures auto-login**: getty autologin on tty1
7. **Creates wrapper script**: `/usr/local/bin/start-kiosk-x`

## Configuration Options

Pass these as environment variables or positional args:

| Variable | Description | Default |
|----------|-------------|---------|
| `KIOSK_URL` | Kiosk web server URL (required) | — |
| `KIOSK_SCALE` | Chromium device scale factor | `1.0` |
| `KIOSK_INVERT` | Invert calendar colors | `false` |
| `KIOSK_SLIDESHOW_INTERVAL` | Photo shuffle interval (minutes) | `15` |
| `KIOSK_USER` | User to run kiosk as | `root` |

## Reconfiguration

To change settings on an existing client, just re-run the script:

```bash
KIOSK_URL=http://<new-server>:<port> sudo ./kiosk-client-setup.sh
sudo reboot
```

## Removal

To remove the kiosk and restore standard desktop behavior:

```bash
KIOSK_ACTION=remove sudo ./kiosk-client-setup.sh
```

This stops/removes the systemd service, deletes all kiosk config files, and restores `multi-user.target` as the default boot target.

To also purge the installed packages:

```bash
apt-get purge -y chromium xorg xinit x11-xserver-utils unclutter unclutter-xfixes
apt-get autoremove -y
```

## Troubleshooting

### Kiosk doesn't start after reboot
- Check: `systemctl get-default` should return `graphical.target`
- Check Xorg: `ps aux | grep Xorg`
- Check Chromium: `chromium --version`
- Run manually: `/root/kiosk-start.sh`
- Check logs: `journalctl -u kiosk.service -n 50`

### Black screen
- Ensure the display is connected and powered on before boot
- Check `/root/kiosk-start.sh` for correct URL
- Verify the kiosk server is reachable from the client: `curl -s http://<server>:8080/health`

### Chromium crashes on startup
- Clear Chromium data: `rm -rf /root/.config/chromium/`
- Check GPU: Try adding `--disable-gpu` to `/root/kiosk-start.sh`
