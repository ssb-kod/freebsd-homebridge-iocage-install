#!/bin/sh
# Install Homebridge + Config UI X directly on FreeBSD 15.x
# (inside an existing jail, or on a plain FreeBSD machine). No iocage needed.
# Node 24, node-gyp, and a rebuild of node-pty for the UI terminal.
#
# Usage (as root, inside the jail or on the machine):
#   fetch https://raw.githubusercontent.com/ssb-kod/freebsd-homebridge-iocage-install/main/freebsd-homebridge-install.sh
#   chmod +x freebsd-homebridge-install.sh
#   script homebridge-install.log ./freebsd-homebridge-install.sh
#
# Rescue / reinstall: safe to run again on an existing install. Config and
# pairings in the storage folder are kept. The iocage script places a copy in
# the jail's /root:
#   cd /root && script homebridge-install.log ./freebsd-homebridge-install.sh
#
# Optional overrides, e.g.:  UI_PORT=8080 sh freebsd-homebridge-install.sh

# Check for root privileges
if ! [ "$(id -u)" = 0 ]; then
  echo "This script must be run with root privileges"
  exit 1
fi

# Settings (override with environment variables)
UI_PORT="${UI_PORT:-8581}"
UI_VERSION="${UI_VERSION:-5.27.0}"   # pinned: newer versions failed the node-pty build
HB_STORAGE="${HB_STORAGE:-/var/lib/homebridge}"
HB_USER="homebridge"
HB_UID="1030"
PTY_DIR="/usr/local/lib/node_modules/homebridge-config-ui-x/node_modules/@homebridge/node-pty-prebuilt-multiarch"
export PYTHON=/usr/local/bin/python3

#####
#
# Packages
#
#####

echo "Installing packages"
env ASSUME_ALWAYS_YES=yes pkg install node24 npm-node24 python3 openssl gcc \
  nss_mdns ffmpeg sudo git nano || { echo "pkg install failed"; exit 1; }

#####
#
# User and storage
#
#####

# Fixed UID/GID so storage ownership is predictable (hb-service reuses this user)
if ! pw groupshow "${HB_USER}" >/dev/null 2>&1; then
  pw groupadd -n "${HB_USER}" -g "${HB_UID}"
fi
if ! pw usershow "${HB_USER}" >/dev/null 2>&1; then
  pw useradd -n "${HB_USER}" -u "${HB_UID}" -g "${HB_UID}" -c 'Homebridge User' \
    -d /nonexistent -s /usr/sbin/nologin
fi

mkdir -p "${HB_STORAGE}"
chown "${HB_USER}":wheel "${HB_STORAGE}"

#####
#
# Homebridge installation
#
#####

echo "Tool versions: node $(node --version), npm $(npm --version), $(${PYTHON} --version)"

echo "Installing homebridge, node-gyp, homebridge-config-ui-x@${UI_VERSION}"
npm install -g homebridge || { echo "homebridge install failed"; exit 1; }
npm install -g --force node-gyp || { echo "node-gyp install failed"; exit 1; }
npm install -g "homebridge-config-ui-x@${UI_VERSION}" || { echo "config-ui-x install failed"; exit 1; }

# Rebuild node-pty from source (prebuilt binaries don't exist for FreeBSD)
echo "Rebuilding node-pty-prebuilt-multiarch"
( cd "${PTY_DIR}" && rm -rf build && node-gyp rebuild ) || { echo "node-pty rebuild failed"; exit 1; }

# Install as a service (creates rc.d script, config.json, and starts Homebridge)
hb-service install --user "${HB_USER}" --port "${UI_PORT}" -U "${HB_STORAGE}"

#####
#
# Summary
#
#####

echo "Global npm packages:"
npm -g ls --depth=0

echo "---------------"
echo "Installation complete."
echo "Testing install..."
sleep 5   # give the UI time to start before checking
hb-service status
echo "If 'Homebridge UI running' is shown above, browse to http://<this machine's IP>:${UI_PORT}"
echo "---------------"
