#!/bin/bash
#
# Kiosk Client Setup & Reconfiguration Script
#
# Sets up a Debian or Ubuntu headless host as a kiosk client, OR
# reconfigures/removes an existing kiosk setup.
#
# Features:
#   - Detects Debian/Ubuntu and installs minimal Xorg + Chromium
#   - Creates/updates /etc/systemd/system/kiosk.service for kiosk mode
#   - Creates/updates /root/kiosk-start.sh with kiosk URL and settings
#   - Configures boot to graphical.target
#   - Idempotent: safe to re-run for reconfiguration
#   - Supports "remove" mode to cleanly uninstall kiosk and restore desktop
#
# Usage:
#   curl -s https://raw.githubusercontent.com/wickedyoda/kiosk/main/kiosk-client-setup.sh | sudo KIOSK_URL=http://<server>:8080 bash
#   # Or with remove mode:
#   curl -s https://raw.githubusercontent.com/wickedyoda/kiosk/main/kiosk-client-setup.sh | sudo KIOSK_ACTION=remove bash
#
# Or (if already cloned):
#   sudo KIOSK_URL=http://<server>:8080 bash kiosk-client-setup.sh
#   sudo KIOSK_ACTION=remove bash kiosk-client-setup.sh
#
# Note: sudo strips unknown env vars by default. Use the form above
# (sudo VAR=value bash) to ensure KIOSK_URL is passed through.
#
# Prerequisites:
#   - Debian 12+ or Ubuntu 22.04+ (headless, no GUI)
#   - Network access to the kiosk web server
#
# Exit codes:
#   0 — Success
#   1 — Invalid arguments or OS not supported
#   2 — Package installation failed
#
set -euo pipefail

# --- Configuration from environment / arguments ---
KIOSK_ACTION="${KIOSK_ACTION:-setup}"  # "setup" or "remove"
KIOSK_URL="${KIOSK_URL:-}"
KIOSK_SCALE="${KIOSK_SCALE:-1.0}"
KIOSK_INVERT="${KIOSK_INVERT:-false}"
KIOSK_USER="${KIOSK_USER:-root}"
KIOSK_SLIDESHOW_INTERVAL="${KIOSK_SLIDESHOW_INTERVAL:-15}"

# Parse positional arguments like KIOSK_URL=<value>
for arg in "$@"; do
    case "$arg" in
        KIOSK_URL=*)                 KIOSK_URL="${arg#KIOSK_URL=}" ;;
        KIOSK_SCALE=*)               KIOSK_SCALE="${arg#KIOSK_SCALE=}" ;;
        KIOSK_INVERT=*)              KIOSK_INVERT="${arg#KIOSK_INVERT=}" ;;
        KIOSK_USER=*)                KIOSK_USER="${arg#KIOSK_USER=}" ;;
        KIOSK_SLIDESHOW_INTERVAL=*)  KIOSK_SLIDESHOW_INTERVAL="${arg#KIOSK_SLIDESHOW_INTERVAL=}" ;;
        KIOSK_ACTION=*)              KIOSK_ACTION="${arg#KIOSK_ACTION=}" ;;
        remove)                      KIOSK_ACTION="remove" ;;
        setup)                       KIOSK_ACTION="setup" ;;
    esac
done

# --- Remove mode ---
if [ "$KIOSK_ACTION" = "remove" ]; then
    echo "=== Kiosk Client Removal ==="
    echo ""

    export DEBIAN_FRONTEND=noninteractive

    # --- Detect OS ---
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "Detected OS: $NAME ($VERSION)"
    fi
    echo ""

    echo "Removing kiosk configuration..."

    # Stop and disable the kiosk service
    systemctl stop kiosk.service 2>/dev/null || true
    systemctl disable kiosk.service 2>/dev/null || true

    # Remove systemd service file
    if [ -f /etc/systemd/system/kiosk.service ]; then
        rm -f /etc/systemd/system/kiosk.service
        echo "  Removed: /etc/systemd/system/kiosk.service"
    fi

    systemctl daemon-reload 2>/dev/null || true

    # Remove kiosk start script
    if [ -f /root/kiosk-start.sh ]; then
        rm -f /root/kiosk-start.sh
        echo "  Removed: /root/kiosk-start.sh"
    fi

    # Remove X session files
    if [ -f /root/.xinitrc ]; then
        rm -f /root/.xinitrc
        echo "  Removed: /root/.xinitrc"
    fi
    if [ -f /root/.xsession ]; then
        rm -f /root/.xsession
        echo "  Removed: /root/.xsession"
    fi

    # Remove the start-kiosk-x wrapper
    if [ -f /usr/local/bin/start-kiosk-x ]; then
        rm -f /usr/local/bin/start-kiosk-x
        echo "  Removed: /usr/local/bin/start-kiosk-x"
    fi

    # Remove getty auto-login override
    if [ -f /etc/systemd/system/getty@tty1.service.d/override.conf ]; then
        rm -f /etc/systemd/system/getty@tty1.service.d/override.conf
        rmdir /etc/systemd/system/getty@tty1.service.d/ 2>/dev/null || true
        echo "  Removed: getty auto-login override"
    fi

    # Restore default boot target to multi-user (standard for servers/desktops)
    systemctl set-default multi-user.target 2>/dev/null || true

    echo ""
    echo "=== Removal Complete ==="
    echo "The kiosk service has been stopped and disabled."
    echo "Systemd service, start scripts, and X session configs have been removed."
    echo "The system will boot to multi-user.target (no automatic GUI login)."
    echo ""
    echo "To keep Chromium installed, do nothing."
    echo "To remove Chromium and Xorg packages:"
    echo "  apt-get purge -y chromium xorg xinit x11-xserver-utils unclutter unclutter-xfixes"
    echo "  apt-get autoremove -y"
    echo ""
    echo "Reboot to apply: sudo reboot"
    exit 0
fi

# --- Setup mode ---

if [ -z "$KIOSK_URL" ]; then
    echo "Usage: sudo KIOSK_URL=http://<server>:<port> bash kiosk-client-setup.sh"
    echo ""
    echo "Example:"
    echo "  curl -s https://raw.githubusercontent.com/wickedyoda/kiosk/main/kiosk-client-setup.sh | sudo KIOSK_URL=http://docker1.tail99133.ts.net:8080 bash"
    echo ""
    echo "Optional env vars:"
    echo "  KIOSK_SCALE=1.5              — Chromium device scale factor (default: 1.0)"
    echo "  KIOSK_INVERT=true            — Invert calendar colors (default: false)"
    echo "  KIOSK_USER=root              — User to run kiosk as (default: root)"
    echo "  KIOSK_SLIDESHOW_INTERVAL=5   — Photo shuffle interval in minutes (default: 15)"
    echo "  WEATHER_ZIP_CODE=71417       — US ZIP code for weather overlay"
    echo ""
    echo "Other actions:"
    echo "  KIOSK_ACTION=remove            — Remove kiosk and restore standard desktop"
    exit 1
fi

# Strip trailing slash
KIOSK_URL=$(echo "$KIOSK_URL" | sed 's:/*$::')

# --- OS Detection ---
echo "=== Kiosk Client Setup ==="
echo "Kiosk URL: $KIOSK_URL"
echo "Scale: $KIOSK_SCALE"
echo "Invert: $KIOSK_INVERT"
echo "Slideshow interval: ${KIOSK_SLIDESHOW_INTERVAL}m"
echo ""

export DEBIAN_FRONTEND=noninteractive

# --- Detect OS ---
if [ ! -f /etc/os-release ]; then
    echo "ERROR: Cannot detect OS. /etc/os-release not found."
    exit 1
fi

. /etc/os-release

OS_NAME="${ID:-unknown}"
OS_VERSION="${VERSION_ID:-unknown}"
OS_LIKE="${ID_LIKE:-}"

echo "Detected OS: $NAME ($VERSION)"
echo ""

# Validate Debian or Ubuntu
SUPPORTED=0
if [ "$OS_NAME" = "debian" ]; then
    SUPPORTED=1
elif [ "$OS_NAME" = "ubuntu" ]; then
    SUPPORTED=1
elif echo "$OS_LIKE" | grep -qw "debian"; then
    SUPPORTED=1
fi

if [ "$SUPPORTED" -eq 0 ]; then
    echo "ERROR: Unsupported OS. This script requires Debian or Ubuntu."
    echo "Detected: OS=$OS_NAME VERSION=$OS_VERSION LIKES=$OS_LIKE"
    echo ""
    echo "Supported: Debian 12+, Ubuntu 22.04+"
    exit 1
fi

echo "OS supported: $NAME $VERSION"
echo ""

# --- Step 1: Install Xorg and Chromium ---
echo "=== Step 1: Installing Xorg + Chromium ==="

apt-get update -qq

# Determine package list
PACKAGES_XORG="xorg xserver-xorg-video-fbdev xinit x11-xserver-utils"
# Use unclutter-xfixes on Debian 12+ / Ubuntu 22.04+, unclutter as fallback
PACKAGES_UNCLUTTER="unclutter"
if [ "$OS_NAME" = "debian" ] && [ -n "$OS_VERSION" ] && [ "$(echo "$OS_VERSION" | cut -d. -f1)" -ge 12 ]; then
    PACKAGES_UNCLUTTER="unclutter-xfixes"
elif [ "$OS_NAME" = "ubuntu" ] && [ -n "$OS_VERSION" ] && [ "$(echo "$OS_VERSION" | cut -d. -f1)" -ge 22 ]; then
    PACKAGES_UNCLUTTER="unclutter-xfixes"
fi

# Check what's already installed
NEED_INSTALL=()
for pkg in $PACKAGES_XORG $PACKAGES_UNCLUTTER; do
    if ! dpkg -l | grep -q "^ii.*$pkg "; then
        NEED_INSTALL+=($pkg)
    fi
done

# Chromium
if ! command -v chromium &>/dev/null && ! command -v chromium-browser &>/dev/null; then
    NEED_INSTALL+=(chromium)
fi

if [ ${#NEED_INSTALL[@]} -gt 0 ]; then
    echo "Installing: ${NEED_INSTALL[*]}"
    if ! apt-get install -y -qq "${NEED_INSTALL[@]}"; then
        echo "ERROR: Package installation failed."
        echo "Try: sudo apt-get update && sudo apt-get install -y ${NEED_INSTALL[*]}"
        exit 2
    fi
else
    echo "All packages already installed."
fi

# Determine chromium binary
if command -v chromium &>/dev/null; then
    CHROMIUM_BIN="chromium"
elif command -v chromium-browser &>/dev/null; then
    CHROMIUM_BIN="chromium-browser"
else
    echo "ERROR: Chromium not found after installation."
    exit 1
fi

echo "Chromium: $CHROMIUM_BIN"

# --- Step 2: Create/overwrite kiosk start script ---
echo "=== Step 2: Creating kiosk start script ==="

KIOSK_SCRIPT="/root/kiosk-start.sh"

cat > "$KIOSK_SCRIPT" << KIOSK_EOF
#!/bin/bash
#
# Kiosk start script — auto-generated by kiosk-client-setup.sh
# URL: $KIOSK_URL
# Scale: $KIOSK_SCALE
# Invert: $KIOSK_INVERT
#

# Disable screen blanking and power management
xset s off
xset s noblank
xset -dpms

# Hide cursor (uses whichever is available)
if command -v unclutter &>/dev/null; then
    unclutter -idle 2 -root 2>/dev/null &
elif command -v unclutter-xfixes &>/dev/null; then
    unclutter-xfixes -idle 2 -root 2>/dev/null &
fi

# Start Chromium in kiosk mode
$CHROMIUM_BIN \\
  --noerrdialogs \\
  --disable-infobars \\
  --no-first-run \\
  --no-default-browser-check \\
  --disable-session-crashed-bubble \\
  --kiosk \\
  --force-device-scale-factor=$KIOSK_SCALE \\
  --disable-features=Translate \\
  --disable-web-security \\
  --allow-running-insecure-content \\
  --disable-gpu-compositing \\
  "$KIOSK_URL"
KIOSK_EOF

chmod +x "$KIOSK_SCRIPT"
echo "Kiosk script: $KIOSK_SCRIPT"

# --- Step 3: Create/overwrite X session ---
echo "=== Step 3: Configuring X session ==="

cat > /root/.xinitrc << 'XINITRC_EOF'
#!/bin/bash
xset s off
xset s noblank
xset -dpms
exec /root/kiosk-start.sh
XINITRC_EOF
chmod +x /root/.xinitrc

cat > /root/.xsession << 'XSESSION_EOF'
#!/bin/bash
xset s off
xset s noblank
xset -dpms
exec /root/kiosk-start.sh
XSESSION_EOF
chmod +x /root/.xsession

# --- Step 4: Configure graphical boot target ---
echo "=== Step 4: Configuring boot to graphical target ==="
systemctl set-default graphical.target 2>/dev/null || true

# --- Step 5: Create/overwrite systemd service ---
echo "=== Step 5: Creating systemd service ==="

SYSTEMD_SERVICE="/etc/systemd/system/kiosk.service"

cat > "$SYSTEMD_SERVICE" << 'SYSTEMD_EOF'
[Unit]
Description=Kiosk Mode
After=graphical-session.target
Wants=graphical-session.target

[Service]
Type=simple
User=root
Group=root
Environment=DISPLAY=:0
Environment=XAUTHORITY=/root/.Xauthority
ExecStart=/root/kiosk-start.sh
Restart=always
RestartSec=3
StandardInput=tty

[Install]
WantedBy=graphical.target
SYSTEMD_EOF

chmod 644 "$SYSTEMD_SERVICE"
systemctl daemon-reload
systemctl enable kiosk.service 2>/dev/null || true

echo "Systemd service: $SYSTEMD_SERVICE"

# --- Step 6: Create auto-login for getty (serial/console fallback) ---
echo "=== Step 6: Configuring auto-login ==="

GETTY_DIR="/etc/systemd/system/getty@tty1.service.d"
mkdir -p "$GETTY_DIR"

cat > "$GETTY_DIR/override.conf" << 'GETTY_EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
Type=idle
GETTY_EOF

# --- Step 7: Create wrapper to launch X + kiosk ---
echo "=== Step 7: Configuring session launch ==="

cat > /usr/local/bin/start-kiosk-x << 'STARTX_EOF'
#!/bin/bash
# Start X server and run kiosk
exec startx /root/.xinitrc -- -nocursor -nolisten tcp -noreset
STARTX_EOF

chmod +x /usr/local/bin/start-kiosk-x

# --- Summary ---
echo ""
echo "=== Setup Complete ==="
echo ""
echo "Configuration:"
echo "  OS: $NAME $VERSION"
echo "  Kiosk URL: $KIOSK_URL"
echo "  Scale: $KIOSK_SCALE"
echo "  Invert: $KIOSK_INVERT"
echo "  Slideshow: every ${KIOSK_SLIDESHOW_INTERVAL}m"
echo "  User: $KIOSK_USER"
echo ""
echo "Files created:"
echo "  $KIOSK_SCRIPT — kiosk start script"
echo "  /root/.xinitrc — X session init"
echo "  /root/.xsession — display manager session"
echo "  $SYSTEMD_SERVICE — systemd service"
echo ""
echo "To start now: sudo systemctl start kiosk.service"
echo "Or reboot: sudo reboot"
echo ""
echo "To reconfigure later with a different URL:"
echo "  KIOSK_URL=http://<new-server>:<port> sudo bash kiosk-client-setup.sh"
echo ""
echo "To remove kiosk and restore desktop:"
echo "  KIOSK_ACTION=remove sudo bash kiosk-client-setup.sh"
