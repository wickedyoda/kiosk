# Client Setup Guide

This guide covers setting up a Debian or Ubuntu headless machine as a kiosk client that displays the Kiosk web application full-screen on boot.

## Prerequisites

- Debian 12 (Bookworm) or Debian 13 (Trixy), or Ubuntu 22.04+
- No GUI installed (headless)
- Network access to reach the kiosk web server
- Root/sudo privileges

## Quick Setup (Interactive)

```bash
curl -s https://raw.githubusercontent.com/wickedyoda/kiosk/main/kiosk-client-setup.sh | sudo bash
```

You'll see a menu:

```
What would you like to do?
  1) Install a NEW kiosk (fails if already installed)
  2) UPDATE existing kiosk settings (requires existing installation)
  3) Uninstall and remove the kiosk
```

## Quick Setup (Non-Interactive)

```bash
# Install new kiosk
curl -s https://raw.githubusercontent.com/wickedyoda/kiosk/main/kiosk-client-setup.sh | sudo KIOSK_URL=http://<server-ip>:8080 KIOSK_ACTION=install bash
sudo reboot

# Reconfigure existing kiosk (change URL)
curl -s https://raw.githubusercontent.com/wickedyoda/kiosk/main/kiosk-client-setup.sh | sudo KIOSK_URL=http://<new-server>:<port> KIOSK_ACTION=update bash
sudo reboot

# Remove kiosk
curl -s https://raw.githubusercontent.com/wickedyoda/kiosk/main/kiosk-client-setup.sh | sudo KIOSK_ACTION=remove bash
```

## What the Script Does

1. **Installs packages**: Xorg, Chromium, xinit, unclutter
2. **Creates `/root/kiosk-start.sh`**: Launches Chromium in kiosk mode
3. **Configures X session files**: `/root/.xinitrc` and `/root/.xsession`
- **Sets boot target**: `multi-user.target` (systemd service handles X + Chromium) instead of `graphical.target`
- **Creates systemd service**: `/etc/systemd/system/kiosk.service` (starts X + Chromium automatically at boot)
- **Creates wrapper script**: `/usr/local/bin/start-kiosk-x` (launches X server)

## Configuration Options

Pass these as environment variables before `bash`:

| Variable | Description | Default |
|----------|-------------|---------|
| `KIOSK_URL` | Kiosk web server URL (required for install/update) | — |
| `KIOSK_SCALE` | Chromium device scale factor | `1.0` |
| `KIOSK_INVERT` | Invert calendar colors | `false` |
| `KIOSK_SLIDESHOW_INTERVAL` | Photo shuffle interval (minutes) | `15` |
| `KIOSK_USER` | User to run kiosk as | `root` |
| `KIOSK_ACTION` | `install`, `update`, or `remove` | _(interactive prompt)_ |

## Reconfiguration

To change settings on an existing client:

```bash
sudo KIOSK_URL=http://<new-server>:<port> KIOSK_ACTION=update bash kiosk-client-setup.sh
sudo reboot
```

## Removal

To remove the kiosk and restore standard desktop behavior:

```bash
sudo KIOSK_ACTION=remove bash kiosk-client-setup.sh
```

This stops/removes the systemd service, deletes all kiosk config files, and restores `multi-user.target` as the default boot target.

To also purge the installed packages:

```bash
apt-get purge -y chromium xorg xinit x11-xserver-utils unclutter unclutter-xfixes
apt-get autoremove -y
```

## Troubleshooting

### Kiosk doesn't start after reboot
- Check: `systemctl get-default` should return `multi-user.target`
- Check kiosk service: `systemctl status kiosk.service`
- Check Xorg: `ps aux | grep Xorg` (should be started by the systemd service)
- Check Chromium: `chromium --version`
- Run manually: `/usr/local/bin/start-kiosk-x`
- Check logs: `journalctl -u kiosk.service -n 50`

### Black screen
- Ensure the display is connected and powered on before boot
- Check `/root/kiosk-start.sh` for correct URL
- Verify the kiosk server is reachable from the client: `curl -s http://<server>:8080/health`

### Chromium crashes on startup
- Clear Chromium data: `rm -rf /root/.config/chromium/`
- Check GPU: Try adding `--disable-gpu` to `/root/kiosk-start.sh`
