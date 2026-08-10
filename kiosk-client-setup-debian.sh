#!/bin/bash
#
# Kiosk Client Setup Script for Debian-based systems (Debian 12+, Ubuntu 22.04+)
#
# This script:
#   1. Installs Chromium browser
#   2. Creates an X session that launches a full-screen kiosk pointing to the kiosk URL
#   3. Auto-starts the kiosk on boot
#
# Usage:
#   curl -s https://raw.githubusercontent.com/wickedyoda/kiosk/main/kiosk-client-setup-debian.sh | KIOSK_URL=http://YOUR-KIOSK-SERVER:8080 sudo bash
#
# Or after cloning:
#   sudo ./kiosk-client-setup-debian.sh KIOSK_URL=http://YOUR-KIOSK-SERVER:8080
#
# Requirements:
#   - Debian 12 (Bookworm) or Ubuntu 22.04+ with desktop environment
#   - The kiosk web server must be reachable
#
# The script auto-detects the desktop environment and creates an X session
# that launches Chromium in kiosk mode on boot or login.
#
set -euo pipefail

# --- Parse arguments ---
KIOSK_URL="${KIOSK_URL:-}"
# Allow positional argument as fallback
if [ -z "$KIOSK_URL" ]; then
    if [ $# -ge 2 ] && [ "$1" = "KIOSK_URL" ]; then
        KIOSK_URL="$2"
    fi
fi

if [ -z "$KIOSK_URL" ]; then
    echo "Usage: KIOSK_URL=http://<server>:<port> sudo bash kiosk-client-setup-debian.sh"
    echo "Example: KIOSK_URL=http://192.168.1.100:8080 sudo bash kiosk-client-setup-debian.sh"
    exit 1
fi

# Strip trailing slash
KIOSK_URL=$(echo "$KIOSK_URL" | sed 's:/*$::')

echo "=== Kiosk Client Setup (Debian/Ubuntu) ==="
echo "Kiosk URL: $KIOSK_URL"
echo ""

# --- Detect current user ---
if [ "$(id -u)" -eq 0 ]; then
    # Running as root — detect the "real" desktop user
    KIOSK_USER="${KIOSK_USER:-}"
    if [ -z "$KIOSK_USER" ]; then
        # Try to find the first non-root user with a home directory
        KIOSK_USER=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}')
    fi
    if [ -z "$KIOSK_USER" ]; then
        echo "Could not detect a desktop user. Set KIOSK_USER env var."
        echo "Example: KIOSK_USER=youruser sudo bash kiosk-client-setup-debian.sh"
        exit 1
    fi
    HOME_DIR=$(getent passwd "$KIOSK_USER" | cut -d: -f6)
else
    KIOSK_USER="$(whoami)"
    HOME_DIR="$HOME"
fi

echo "Kiosk user: $KIOSK_USER"
echo "Home directory: $HOME_DIR"
echo ""

# --- Step 1: Install Chromium and required packages ---
echo "Installing Chromium and utilities..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    chromium \
    x11-xserver-utils \
    unclutter \
    xset \
    wget \
    2>/dev/null

# Chromium binary may be 'chromium' or 'chromium-browser' depending on distro
if command -v chromium &>/dev/null; then
    CHROMIUM_BIN="chromium"
elif command -v chromium-browser &>/dev/null; then
    CHROMIUM_BIN="chromium-browser"
else
    echo "ERROR: Chromium not found after installation"
    exit 1
fi
echo "Chromium binary: $CHROMIUM_BIN"

# --- Step 2: Create kiosk start script ---
KIOSK_SCRIPT="$HOME_DIR/kiosk-start.sh"
echo "Creating kiosk start script at $KIOSK_SCRIPT..."
sudo -u "$KIOSK_USER" mkdir -p "$HOME_DIR" 2>/dev/null || true

sudo tee "$KIOSK_SCRIPT" > /dev/null << EOF
#!/bin/bash

# Kiosk start script — launches Chromium in fullscreen kiosk mode
# Pointing to: $KIOSK_URL

# Disable screen blanking and power management
xset s off
xset s noblank
xset -dpms

# Hide cursor after 2 seconds of inactivity
unclutter -idle 2 -root &

# Start Chromium in kiosk mode
# --noerrdialogs:     suppress error dialogs
# --disable-infobars:  hide the "automation" info bar
# --no-first-run:      skip first-run setup
# --kiosk:             fullscreen kiosk mode
# --disable-features=Translate: disable translation bar
# --force-device-scale-factor=1: avoid scaling issues
# --no-default-browser-check: skip default browser check
# --disable-session-crashed-bubble: suppress crash bubbles
$CHROMIUM_BIN \\
  --noerrdialogs \\
  --disable-infobars \\
  --no-first-run \\
  --no-default-browser-check \\
  --disable-session-crashed-bubble \\
  --kiosk \\
  --force-device-scale-factor=1 \\
  --disable-features=Translate \\
  --disable-web-security \\
  --allow-running-insecure-content \\
  "$KIOSK_URL"
EOF

sudo chmod +x "$KIOSK_SCRIPT"
sudo chown "$KIOSK_USER":"$KIOSK_USER" "$KIOSK_SCRIPT"

# --- Step 3: Set up autostart based on desktop environment ---
echo "Detecting desktop environment..."

# Try to detect the desktop environment from the .xsession or autostart
AUTOSTART_DIR_DEBIAN="$HOME_DIR/.config/autostart"
AUTOSTART_DIR_LXDE="$HOME_DIR/.config/lxsession/LXDE-pi"
AUTOSTART_DIR_LXDE_DEBIAN="$HOME_DIR/.config/lxsession/LXDE"
XSSESSION_FILE="$HOME_DIR/.xsession"

sudo -u "$KIOSK_USER" mkdir -p "$AUTOSTART_DIR_DEBIAN" 2>/dev/null || true
sudo -u "$KIOSK_USER" mkdir -p "$AUTOSTART_DIR_LXDE" 2>/dev/null || true
sudo -u "$KIOSK_USER" mkdir -p "$AUTOSTART_DIR_LXDE_DEBIAN" 2>/dev/null || true

# Method 1: .xsession file (works with most display managers / startx)
echo "Setting up .xsession..."
sudo -u "$KIOSK_USER" tee "$XSSESSION_FILE" > /dev/null << EOF
xset s off
xset s noblank
xset -dpms
unclutter -idle 2 -root &
$CHROMIUM_BIN --noerrdialogs --disable-infobars --no-first-run --no-default-browser-check --disable-session-crashed-bubble --kiosk --force-device-scale-factor=1 --disable-features=Translate --disable-web-security --allow-running-insecure-content "$KIOSK_URL"
EOF
sudo chown "$KIOSK_USER":"$KIOSK_USER" "$XSSESSION_FILE"

# Method 2: .config/autostart/kiosk.desktop (works with GNOME, KDE, XFCE, etc.)
echo "Setting up autostart .desktop entry..."
sudo -u "$KIOSK_USER" tee "$AUTOSTART_DIR_DEBIAN/kiosk.desktop" > /dev/null << EOF
[Desktop Entry]
Type=Application
Name=Kiosk
Exec=$KIOSK_SCRIPT
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=0
EOF

# Method 3: LXDE autostart (for Raspberry Pi OS / LXDE)
for lxde_dir in "$AUTOSTART_DIR_LXDE" "$AUTOSTART_DIR_LXDE_DEBIAN"; do
    if [ -d "$lxde_dir" ]; then
        sudo -u "$KIOSK_USER" tee "$lxde_dir/autostart" > /dev/null << EOF
@xset s off
@xset s noblank
@xset -dpms
@unclutter -idle 2 -root
@$KIOSK_SCRIPT
EOF
        sudo chown -R "$KIOSK_USER":"$KIOSK_USER" "$lxde_dir"
    fi
done

# --- Step 4: Configure auto-login (for systems using getty/display-manager) ---
# Set up TTY autologin for the kiosk user (if no display manager)
echo "Configuring auto-login..."
if command -v raspi-config &>/dev/null; then
    # Raspberry Pi OS
    sudo raspi-config nonint do_boot_bsp 2>/dev/null || true   # boot to desktop
    sudo raspi-config nonint do_boot_wait 0 2>/dev/null || true  # no wait for network
fi

# --- Step 5: Create systemd service (alternative to autostart) ---
SYSTEMD_SERVICE="/etc/systemd/system/kiosk.service"
echo "Creating systemd kiosk service..."
tee "$SYSTEMD_SERVICE" > /dev/null << EOF
[Unit]
Description=Kiosk Mode
After=graphical-session.target
Wants=graphical-session.target

[Service]
User=$KIOSK_USER
Group=$KIOSK_USER
Environment=DISPLAY=:0
Environment=XAUTHORITY=$HOME_DIR/.Xauthority
ExecStart=$KIOSK_SCRIPT
Restart=always
RestartSec=5
StandardInput=tty

[Install]
WantedBy=graphical.target
EOF

chmod 644 "$SYSTEMD_SERVICE"
systemctl daemon-reload
# Don't enable by default — autostart via .desktop is usually sufficient
# systemctl enable kiosk.service

echo "Systemd service created (enable with: sudo systemctl enable --now kiosk.service)"
echo ""

# --- Step 6: Disable screensaver/lock in common desktop environments ---
echo "Configuring power management settings..."

# GNOME
if [ -f "/etc/whoami" ] || command -v gsettings &>/dev/null; then
    sudo -u "$KIOSK_USER" gsettings set org.gnome.desktop.screensaver idle-ub 0 2>/dev/null || true
    sudo -u "$KIOSK_USER" gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null || true
fi

# XFCE
sudo -u "$KIOSK_USER" xfconf-query -c xfce4-session -p /startup/idle-ub 0 2>/dev/null || true

# KDE
if [ -d "$HOME_DIR/.config" ]; then
    sudo -u "$KIOSK_USER" mkdir -p "$HOME_DIR/.config/autostart" 2>/dev/null || true
fi

# --- Step 7: Configure display-manager auto-login (lightdm, sddm, gdm) ---
# Detect display manager
if [ -f "/etc/lightdm/lightdm.conf" ] || command -v lightdm &>/dev/null; then
    echo "Configuring LightDM auto-login..."
    mkdir -p /etc/lightdm
    cat > /etc/lightdm/lightdm.conf.d/10-kiosk.conf << EOF
[Seat:*]
autologin-user=$KIOSK_USER
autologin-user-timeout=0
user-session=default
EOF
    systemctl enable lightdm 2>/dev/null || true
elif [ -f "/etc/sddm.conf" ] || command -v sddm &>/dev/null; then
    echo "Configuring SDDM auto-login..."
    cat > /etc/sddm.conf.d/10-kiosk.conf << EOF
[Autologin]
User=$KIOSK_USER
Session=
EOF
elif [ -f "/etc/gdm3/greeter.dconf-defaults" ] || command -v gdm3 &>/dev/null 2>&1; then
    echo "Configuring GDM3 auto-login..."
    mkdir -p /etc/dconf/profile
    tee /etc/dconf/profile/user > /dev/null << DBEOF
user-db:user
system-db:local
DBEOF
    mkdir -p /etc/dconf/db/local.d
    tee /etc/dconf/db/local.d/01-kiosk > /dev/null << DBEOF
[org/gnome/login-screen]
enable-auto-login=true
autologin-user='$KIOSK_USER'

[org/gnome/desktop-screensaver]
idle-ub=0
DBEOF
    systemctl enable gdm3 2>/dev/null || true
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "The kiosk will start automatically:"
echo "  - On login via .config/autostart/kiosk.desktop"
echo "  - Via .xsession on X session start"
echo ""
echo "Kiosk is pointing to: $KIOSK_URL"
echo "Kiosk script: $KIOSK_SCRIPT"
echo ""
echo "To test now: sudo -u $KIOSK_USER $KIOSK_SCRIPT"
echo "To reboot: sudo reboot"
echo ""
echo "Note: Make sure the kiosk can reach the server at $KIOSK_URL"
echo "For Nginx reverse proxy: set BASE_URL and TRUST_PROXY in the server .env"
