#!/bin/bash
#
# Kiosk Client Setup Script for Raspberry Pi (Raspbian / Raspberry Pi OS)
#
# This script:
#   1. Installs Chromium browser
#   2. Creates a systemd service that launches the Pi in kiosk mode
#   3. Points Chromium to the kiosk web server URL
#
# Usage:
#   curl -s https://raw.githubusercontent.com/wickedyoda/kiosk/main/kiosk-client-setup.sh | KIOSK_URL=http://YOUR-KIOSK-SERVER:8080 sudo bash
#
# Or after cloning:
#   sudo ./kiosk-client-setup.sh KIOSK_URL=http://YOUR-KIOSK-SERVER:8080
#
# Requirements:
#   - Raspberry Pi running Raspberry Pi OS (64-bit recommended)
#   - The kiosk web server must be reachable from the Pi
#   - The Pi must boot to the desktop (Graphical UI enabled)

set -euo pipefail

# --- Parse arguments ---
KIOSK_URL="${KIOSK_URL:-}"
if [ -z "$KIOSK_URL" ]; then
    echo "Usage: KIOSK_URL=http://<server>:<port> sudo bash kiosk-client-setup.sh"
    echo "Example: KIOSK_URL=http://192.168.1.100:8080 sudo bash kiosk-client-setup.sh"
    exit 1
fi

# Strip trailing slash
KIOSK_URL=$(echo "$KIOSK_URL" | sed 's:/*$::')

echo "=== Kiosk Client Setup ==="
echo "Kiosk URL: $KIOSK_URL"
echo ""

# --- Step 1: Install Chromium ---
echo "Installing Chromium browser..."
sudo apt-get update -qq
sudo apt-get install -y -qq chromium-browser x11-xserver-utils unclutter xset

# --- Step 2: Create kiosk autostart script ---
KIOSK_SCRIPT="/home/pi/kiosk-start.sh"
echo "Creating kiosk start script at $KIOSK_SCRIPT..."
sudo tee "$KIOSK_SCRIPT" > /dev/null <<'EOF'
#!/bin/bash

# Disable screen blanking and power management
xset s off
xset s noblank
xset -dpms

# Hide cursor after 2 seconds of inactivity
unclutter -idle 2 -root &

# Start Chromium in kiosk mode
# --noerrdialogs: suppress error dialogs
# --disable-infobars: hide the "automation" info bar
# --no-first-run: skip first-run setup
# --kiosk: fullscreen kiosk mode
# --disable-features=Translate: disable translation bar
# --force-device-scale-factor=1: avoid scaling issues
chromium-browser \
  --noerrdialogs \
  --disable-infobars \
  --no-first-run \
  --kiosk \
  --disable-features=Translate \
  --force-device-scale-factor=1 \
  --disable-web-security \
  --allow-running-insecure-content \
  KIOSK_URL_PLACEHOLDER
EOF

# Replace placeholder with actual URL
sudo sed -i "s|KIOSK_URL_PLACEHOLDER|$KIOSK_URL|g" "$KIOSK_SCRIPT"
sudo chmod +x "$KIOSK_SCRIPT"

# --- Step 3: Autostart on boot ---
AUTOSTART_DIR="/home/pi/.config/lxsession/LXDE-pi"
AUTOSTART_FILE="$AUTOSTART_DIR/autostart"

echo "Setting up autostart..."
mkdir -p "$AUTOSTART_DIR"

# Write the autostart file (overwrites any existing one)
cat > "$AUTOSTART_FILE" <<'EOF'
@lxpanel --profile LXDE-pi
@pcmanfm --desktop --profile LXDE-pi
@xscreensaver -no-splash
@/home/pi/kiosk-start.sh
EOF

# --- Step 4: Disable screensaver and screen blanking system-wide ---
XSESSION_FILE="/etc/xdg/lxsession/LXDE-pi/desktop.conf"
if [ -f "$XSESSION_FILE" ]; then
    sudo sed -i 's/#@xterm/@chromium-browser/g' "$XSESSION_FILE" 2>/dev/null || true
fi

# --- Step 5: Configure Pi to auto-login to desktop on boot ---
echo "Configuring auto-login to desktop..."
sudo raspi-config nonint do_boot_bsp 2>/dev/null || true   # boot to desktop
sudo raspi-config nonint do_boot_wait 0  2>/dev/null || true  # no wait for network

# --- Step 6: Create systemd service for kiosk (alternative method) ---
SYSTEMD_SERVICE="/etc/systemd/system/kiosk.service"
echo "Creating systemd kiosk service..."
sudo tee "$SYSTEMD_SERVICE" > /dev/null <<'EOF'
[Unit]
Description=Pi Kiosk Mode
After=graphical.target

[Service]
User=pi
Group=pi
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/pi/.Xauthority
ExecStart=/home/pi/kiosk-start.sh
Restart=always
RestartSec=5

[Install]
WantedBy=graphical.target
EOF

sudo chmod 644 "$SYSTEMD_SERVICE"
sudo systemctl daemon-reload
echo "Systemd service created (will activate on next boot)"

# --- Step 7: Disable swap (optional but recommended for kiosk stability) ---
# sudo dphys-swapfile swapoff
# sudo dphys-swapfile swapon

echo ""
echo "=== Setup Complete ==="
echo ""
echo "The Pi will now boot into kiosk mode on next reboot."
echo "Kiosk is pointing to: $KIOSK_URL"
echo ""
echo "To test now, run: /home/pi/kiosk-start.sh"
echo "To reboot: sudo reboot"
echo ""
echo "Note: Make sure the Pi can reach the kiosk server at $KIOSK_URL"
echo "If using a local server, ensure the firewall allows the connection."
