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
#   - Configures boot to multi-user.target (no login screen)
#   - Idempotent: safe to re-run for reconfiguration
#   - Supports interactive menu: install, update, or remove
#
# Usage:
#   # For interactive menu: save script first, then run
#   curl -s https://raw.githubusercontent.com/wickedyoda/kiosk/main/kiosk-client-setup.sh -o kiosk-client-setup.sh
#   sudo bash kiosk-client-setup.sh
#
#   # Non-interactive (pass env vars - works with pipe)
#   curl -s https://raw.githubusercontent.com/wickedyoda/kiosk/main/kiosk-client-setup.sh | sudo KIOSK_URL=http://<server>:8080 KIOSK_ACTION=install bash
#   curl -s https://raw.githubusercontent.com/wickedyoda/kiosk/main/kiosk-client-setup.sh | sudo KIOSK_ACTION=remove bash
#
# Prerequisites:
#   - Debian 12+ or Ubuntu 22.04+ (headless, no GUI)
#   - Network access to the kiosk web server
#
set -euo pipefail

# --- Default configuration ---
# Check env vars BEFORE setting defaults (env vars may already be set by sudo)
KIOSK_URL="${KIOSK_URL:-}"
KIOSK_SCALE="${KIOSK_SCALE:-1.0}"
KIOSK_INVERT="${KIOSK_INVERT:-false}"
KIOSK_USER="${KIOSK_USER:-root}"
KIOSK_SLIDESHOW_INTERVAL="${KIOSK_SLIDESHOW_INTERVAL:-15}"
KIOSK_ACTION="${KIOSK_ACTION:-}"
WEATHER_ZIP_CODE="${WEATHER_ZIP_CODE:-}"
WEATHER_API_KEY="${WEATHER_API_KEY:-}"

# Parse positional arguments
for arg in "$@"; do
    case "$arg" in
        KIOSK_URL=*)                 KIOSK_URL="${arg#KIOSK_URL=}";;
        KIOSK_SCALE=*)               KIOSK_SCALE="${arg#KIOSK_SCALE=}";;
        KIOSK_INVERT=*)              KIOSK_INVERT="${arg#KIOSK_INVERT=}";;
        KIOSK_USER=*)                KIOSK_USER="${arg#KIOSK_USER=}";;
        KIOSK_SLIDESHOW_INTERVAL=*)  KIOSK_SLIDESHOW_INTERVAL="${arg#KIOSK_SLIDESHOW_INTERVAL=}";;
        KIOSK_ACTION=*)              KIOSK_ACTION="${arg#KIOSK_ACTION=}";;
        WEATHER_ZIP_CODE=*)          WEATHER_ZIP_CODE="${arg#WEATHER_ZIP_CODE=}";;
        WEATHER_API_KEY=*)           WEATHER_API_KEY="${arg#WEATHER_API_KEY=}";;
        remove|uninstall)            KIOSK_ACTION="remove";;
        setup|install|update)        KIOSK_ACTION="setup";;
        *) echo "Unknown argument: $arg";;
    esac
done

# --- Check if kiosk is already installed ---
KIOSK_INSTALLED=0
if [ -f /etc/systemd/system/kiosk.service ]; then
    KIOSK_INSTALLED=1
fi

# --- Check if running interactively (stdin is a terminal) ---
# When piped via curl | sudo bash, stdin is not a terminal, so
# interactive prompts won't work. We need to tell the user to save
# the script first.
CAN_READ_TTY=0
if [ -t 0 ]; then
    CAN_READ_TTY=1
fi

# --- Interactive prompt if no action specified ---
if [ -z "$KIOSK_ACTION" ]; then
    echo "=== Kiosk Client Management ==="
    echo ""
    echo "What would you like to do?"
    echo ""
    echo "  1) Install a NEW kiosk (fails if already installed)"
    echo "  2) UPDATE existing kiosk settings (requires existing installation)"
    echo "  3) Uninstall and remove the kiosk"
    echo ""
    if [ "$CAN_READ_TTY" -eq 1 ]; then
        read -rp "Select an option (1/2/3): " choice
    else
        echo ""
        echo "ERROR: Interactive mode requires a terminal. You are running this script piped via curl."
        echo "Please save the script first and run it directly:"
        echo "  curl -s https://raw.githubusercontent.com/wickedyoda/kiosk/main/kiosk-client-setup.sh -o kiosk-client-setup.sh"
        echo "  sudo KIOSK_URL=http://your-server:8080 bash kiosk-client-setup.sh"
        echo ""
        echo "Or specify the action directly as an environment variable:"
        echo "  curl -s https://raw.githubusercontent.com/wickedyoda/kiosk/main/kiosk-client-setup.sh | sudo KIOSK_ACTION=remove bash"
        echo "  curl -s https://raw.githubusercontent.com/wickedyoda/kiosk/main/kiosk-client-setup.sh | sudo KIOSK_URL=http://<server>:8080 KIOSK_ACTION=install bash"
        exit 1
    fi
    echo ""
    case "$choice" in
        1) KIOSK_ACTION="install";;
        2)
            if [ "$KIOSK_INSTALLED" -eq 0 ]; then
                echo "ERROR: No existing kiosk installation found. Choose option 1 to install first."
                exit 1
            fi
            KIOSK_ACTION="update";;
        3) KIOSK_ACTION="remove";;
        *) echo "ERROR: Invalid option '$choice'"; exit 1;;
    esac
fi

# --- Remove mode ---
if [ "$KIOSK_ACTION" = "remove" ]; then
    echo "=== Kiosk Client Removal ==="
    echo ""

    export DEBIAN_FRONTEND=noninteractive

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

    # Remove getty auto-login override (kept for backward compat)
    if [ -f /etc/systemd/system/getty@tty1.service.d/override.conf ]; then
        rm -f /etc/systemd/system/getty@tty1.service.d/override.conf
        rmdir /etc/systemd/system/getty@tty1.service.d/ 2>/dev/null || true
        echo "  Removed: getty auto-login override"
    fi

    # Remove Xwrapper config
    if [ -f /etc/X11/Xwrapper.config ]; then
        rm -f /etc/X11/Xwrapper.config
        echo "  Removed: /etc/X11/Xwrapper.config"
    fi

    # Restore default boot target to multi-user
    systemctl set-default multi-user.target 2>/dev/null || true

    echo ""
    echo "=== Removal Complete ==="
    echo "The kiosk service has been stopped and disabled."
    echo "Systemd service, start scripts, and X session configs have been removed."
    echo "The system will boot to multi-user.target (standard CLI boot)."
    echo ""
    echo "To keep Chromium installed, do nothing."
    echo "To remove Chromium and Xorg packages:"
    echo "  apt-get purge -y chromium xorg xinit x11-xserver-utils unclutter unclutter-xfixes"
    echo "  apt-get autoremove -y"
    echo ""
    echo "Reboot to apply: sudo reboot"
    exit 0
fi

# --- Setup mode (install or update) ---
# Handle install vs update actions
if [ "$KIOSK_ACTION" = "install" ] && [ "$KIOSK_INSTALLED" -eq 1 ]; then
    echo "ERROR: A kiosk is already installed."
    echo "Use option 2 (Update) to modify settings, or option 3 (Uninstall) to remove."
    echo ""
    read -rp "Continue anyway and overwrite? (y/N) " overwrite
    if [ "$overwrite" != "y" ] && [ "$overwrite" != "Y" ]; then
        echo "Aborting."
        exit 0
    fi
fi

if [ "$KIOSK_ACTION" = "update" ] && [ "$KIOSK_INSTALLED" -eq 1 ]; then
    echo "=== Updating existing kiosk ==="
    # Try to read current KIOSK_URL from the start script
    if [ -f /root/kiosk-start.sh ]; then
        CURRENT_URL=$(grep 'Kiosk URL:' /root/kiosk-start.sh 2>/dev/null | head -1 | sed 's/.*URL: //' || true)
        if [ -n "$CURRENT_URL" ] && [ -z "$KIOSK_URL" ]; then
            echo "Current kiosk URL: $CURRENT_URL"
            echo ""
            echo "Enter new URL (or press Enter to keep current):"
            read -rp "KIOSK_URL: " NEW_URL
            if [ -n "$NEW_URL" ]; then
                KIOSK_URL="$NEW_URL"
            else
                KIOSK_URL="$CURRENT_URL"
            fi
        fi
    fi
    echo ""
fi

# Prompt for KIOSK_URL if not set
if [ -z "$KIOSK_URL" ]; then
    echo ""
    echo "Enter the kiosk server URL (e.g. http://docker1.tail99133.ts.net:8080):"
    read -rp "KIOSK_URL: " KIOSK_URL
    if [ -z "$KIOSK_URL" ]; then
        echo "ERROR: KIOSK_URL is required."
        exit 1
    fi
    KIOSK_URL=$(echo "$KIOSK_URL" | sed 's:/*$::')
    echo ""
fi

# Strip trailing slash
KIOSK_URL=$(echo "$KIOSK_URL" | sed 's:/*$::')

echo ""
echo "=== Kiosk Client Setup ==="
echo "Kiosk URL: $KIOSK_URL"
echo "Scale: $KIOSK_SCALE"
echo "Invert: $KIOSK_INVERT"
echo "Slideshow interval: ${KIOSK_SLIDESHOW_INTERVAL}m"
echo "User: $KIOSK_USER"
echo ""

export DEBIAN_FRONTEND=noninteractive

# --- OS Detection ---
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
    echo ""
    echo "ERROR: Unsupported OS."
    echo "Detected: OS=$OS_NAME VERSION=$OS_VERSION LIKES=$OS_LIKE"
    echo ""
    echo "Supported: Debian 12+, Ubuntu 22.04+"
    echo ""
    read -rp "Continue anyway? (y/N) " cont
    if [ "$cont" ! = "y" ] && [ "$cont" != "Y" ]; then
        echo "Aborting."
        exit 1
    fi
fi

echo "OS supported: $NAME $VERSION"
echo ""

# --- Step 1: Install Xorg and Chromium ---
echo "=== Step 1: Installing Xorg + Chromium ==="

apt-get update -qq

# Determine package list
PACKAGES_XORG="xorg xserver-xorg-video-fbdev xinit x11-xserver-utils"
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

# Build Chromium flags based on invert preference
CHROMIUM_FLAGS="--noerrdialogs --disable-infobars --no-first-run --no-default-browser-check --disable-session-crashed-bubble --kiosk --force-device-scale-factor=$KIOSK_SCALE --disable-features=Translate --disable-web-security --allow-running-insecure-content --no-sandbox --user-data-dir=/root/.config/kioskuim"

if [ "$KIOSK_INVERT" = "true" ]; then
    CHROMIUM_FLAGS="$CHROMIUM_FLAGS --enable-features=WebUIDarkMode --force-dark-mode"
fi

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

# Hide cursor
if command -v unclutter &>/dev/null; then
    unclutter -idle 2 -root 2>/dev/null &
elif command -v unclutter-xfixes &>/dev/null; then
    unclutter-xfixes -idle 2 -root 2>/dev/null &
fi

# Set display env
export DISPLAY=:0
export XAUTHORITY=/root/.Xauthority

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
  --no-sandbox \\
  --user-data-dir=/root/.config/kioskuim \\
  "$KIOSK_URL"
KIOSK_EOF

chmod +x "$KIOSK_SCRIPT"
echo "Kiosk script: $KIOSK_SCRIPT"

# --- Step 3: Create X session ---
echo "=== Step 3: Configuring X session ==="

# Configure Xwrapper to allow starting Xorg from systemd (not just console)
if [ -f /etc/X11/Xwrapper.config ] || [ -d /etc/X11 ]; then
    mkdir -p /etc/X11
    cat > /etc/X11/Xwrapper.config << 'XWRAPPER_EOF'
# Allow Xorg to start from systemd service (not just physical console)
allowed_users=anybody
needs_root_rights=yes
XWRAPPER_EOF
    echo "  Configured: /etc/X11/Xwrapper.config (allowed_users=anybody)"
fi

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

# --- Step 4: Configure boot target ---
echo "=== Step 4: Configuring boot target ==="
systemctl set-default multi-user.target 2>/dev/null || true

# --- Step 5: Create systemd service ---
echo "=== Step 5: Creating systemd service ==="

SYSTEMD_SERVICE="/etc/systemd/system/kiosk.service"

cat > "$SYSTEMD_SERVICE" << 'SYSTEMD_EOF'
[Unit]
Description=Kiosk Mode
After=network.target

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/local/bin/start-kiosk-x
Restart=always
RestartSec=3
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

chmod 644 "$SYSTEMD_SERVICE"
systemctl daemon-reload
systemctl enable kiosk.service 2>/dev/null || true

echo "Systemd service: $SYSTEMD_SERVICE"

# --- Step 6: Create wrapper to launch X + kiosk ---
echo "=== Step 6: Configuring session launch ==="

cat > /usr/local/bin/start-kiosk-x << 'STARTX_EOF'
#!/bin/bash
# Start X server and run kiosk
# Use startx with X wrapper to avoid tty conflicts
exec startx /root/.xinitrc -- -nocursor -nolisten tcp -noreset
STARTX_EOF

chmod +x /usr/local/bin/start-kiosk-x

# --- Summary ---
echo ""
if [ "$KIOSK_ACTION" = "update" ]; then
    echo "=== Update Complete ==="
else
    echo "=== Setup Complete ==="
fi
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
echo "  sudo KIOSK_URL=http://<new-server>:<port> bash kiosk-client-setup.sh"
echo ""
echo "To remove kiosk and restore desktop:"
echo "  sudo KIOSK_ACTION=remove bash kiosk-client-setup.sh"
