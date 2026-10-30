#!/bin/sh
# Build an iocage jail on OpenCORE (TrueNAS CORE) / FreeBSD 15.x with Homebridge + Config UI X
# Node 24, node-gyp, and a rebuild of node-pty for the UI terminal.
#
# Usage (from the OpenCORE / FreeBSD 15.x host, as root):
#   script homebridge-iocage-install.log ./freebsd-homebridge-iocage.sh
# Requires "homebridge-config" in the same directory as this script.
# Copies freebsd-homebridge-install.sh (same directory) into the jail's /root
# as a rescue/reinstall script.

# Check for root privileges
if ! [ "$(id -u)" = 0 ]; then
  echo "This script must be run with root privileges"
  exit 1
fi

#####
#
# General Configuration
#
#####

# Defaults (may be overridden in homebridge-config)
JAIL_IP=""
JAIL_INTERFACES=""
DEFAULT_GW_IP=""
INTERFACE="vnet0"
VNET="on"
JAIL_NAME="homebridge"
UI_PORT="8581"
UI_VERSION="5.27.0"      # pinned: newer versions fail the node-pty build
HB_STORAGE="/var/lib/homebridge"
CONFIG_NAME="homebridge-config"

# Load homebridge-config
SCRIPT=$(readlink -f "$0")
SCRIPTPATH=$(dirname "${SCRIPT}")
if ! [ -e "${SCRIPTPATH}/${CONFIG_NAME}" ]; then
  echo "${SCRIPTPATH}/${CONFIG_NAME} must exist."
  exit 1
fi
. "${SCRIPTPATH}/${CONFIG_NAME}"

# Jail root on the host (used to copy the rescue script into the jail)
JAILS_MOUNT=$(zfs get -H -o value mountpoint "$(iocage get -p)"/iocage)
JAIL_ROOT="${JAILS_MOUNT}/jails/${JAIL_NAME}/root"
RESCUE_SCRIPT="freebsd-homebridge-install.sh"

# Jail release: match host, but use 15.1 if host is still on 15.0
RELEASE=$(freebsd-version | cut -d - -f -1)"-RELEASE"
if [ "${RELEASE}" = "15.0-RELEASE" ]; then
  RELEASE="15.1-RELEASE"
fi

#####
#
# Config Sanity Checks
#
#####

if [ -z "${JAIL_IP}" ]; then
  echo 'Configuration error: JAIL_IP must be set'
  exit 1
fi
if [ -z "${DEFAULT_GW_IP}" ]; then
  echo 'Configuration error: DEFAULT_GW_IP must be set'
  exit 1
fi
if [ -z "${JAIL_INTERFACES}" ]; then
  echo 'JAIL_INTERFACES not set, defaulting to: vnet0:bridge0'
  JAIL_INTERFACES="vnet0:bridge0"
fi

# Split IP and netmask; default to /24 if missing or out of range
IP=$(echo "${JAIL_IP}" | cut -f1 -d/)
NETMASK=$(echo "${JAIL_IP}" | cut -f2 -d/)
if [ "${NETMASK}" = "${IP}" ]; then
  NETMASK="24"
fi
if [ "${NETMASK}" -lt 8 ] || [ "${NETMASK}" -gt 30 ]; then
  NETMASK="24"
fi

#####
#
# Jail Creation
#
#####

cat <<__EOF__ >/tmp/pkg.json
{
  "pkgs": [
  "node24",
  "npm-node24",
  "python3",
  "openssl",
  "gcc",
  "nss_mdns",
  "ffmpeg",
  "sudo",
  "git",
  "nano",
  "mc"
  ]
}
__EOF__

if ! iocage create --name "${JAIL_NAME}" -p /tmp/pkg.json -r "${RELEASE}" \
    interfaces="${JAIL_INTERFACES}" ip4_addr="${INTERFACE}|${IP}/${NETMASK}" \
    defaultrouter="${DEFAULT_GW_IP}" boot="on" host_hostname="${JAIL_NAME}" vnet="${VNET}"
then
  echo "Failed to create jail"
  exit 1
fi
rm /tmp/pkg.json

iocage restart "${JAIL_NAME}"

#####
#
# User, Directories, Services
#
#####

# Fixed UID/GID so storage ownership is predictable (hb-service reuses this user)
iocage exec "${JAIL_NAME}" "pw groupadd -n homebridge -g 1030"
iocage exec "${JAIL_NAME}" "pw useradd -n homebridge -u 1030 -g 1030 -c 'Homebridge User' -d /nonexistent -s /usr/sbin/nologin"

iocage exec "${JAIL_NAME}" "mkdir -p ${HB_STORAGE}"
iocage exec "${JAIL_NAME}" "chown homebridge:wheel ${HB_STORAGE}"

# SSH access (root login enabled - tighten after setup if desired)
iocage exec "${JAIL_NAME}" sysrc sshd_enable="YES"
iocage exec "${JAIL_NAME}" "echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config"
iocage exec "${JAIL_NAME}" service sshd start

#####
#
# Homebridge Installation
#
#####

echo "Jail tool versions:"
iocage exec "${JAIL_NAME}" /bin/sh -c 'echo "node $(node --version), npm $(npm --version), $(/usr/local/bin/python3 --version)"'

echo "Installing homebridge, node-gyp, homebridge-config-ui-x@${UI_VERSION}"
iocage exec "${JAIL_NAME}" /bin/sh -c "export PYTHON=/usr/local/bin/python3 && \
  npm install -g homebridge && \
  npm install -g --force node-gyp && \
  npm install -g homebridge-config-ui-x@${UI_VERSION}"

# Rebuild node-pty from source (prebuilt binaries don't exist for FreeBSD)
echo "Rebuilding node-pty-prebuilt-multiarch"
iocage exec "${JAIL_NAME}" /bin/sh -c "export PYTHON=/usr/local/bin/python3 && \
  cd /usr/local/lib/node_modules/homebridge-config-ui-x/node_modules/@homebridge/node-pty-prebuilt-multiarch && \
  rm -rf build && node-gyp rebuild"

# Install as a service (creates rc.d script, config.json, and starts Homebridge)
iocage exec "${JAIL_NAME}" "hb-service install --user homebridge --port ${UI_PORT} -U ${HB_STORAGE}"

#####
#
# Rescue script
#
#####

# Copy the in-place install script into the jail for disaster recovery
# (e.g. after a Homebridge UI update from the web UI breaks the install)
if [ -e "${SCRIPTPATH}/${RESCUE_SCRIPT}" ] && [ -d "${JAIL_ROOT}/root" ]; then
  cp "${SCRIPTPATH}/${RESCUE_SCRIPT}" "${JAIL_ROOT}/root/${RESCUE_SCRIPT}"
  chmod 755 "${JAIL_ROOT}/root/${RESCUE_SCRIPT}"
  echo "Rescue script copied to /root/${RESCUE_SCRIPT} in the jail"
else
  echo "Note: ${RESCUE_SCRIPT} not found next to this script; rescue copy skipped"
fi

#####
#
# Summary
#
#####

echo "Global npm packages:"
iocage exec "${JAIL_NAME}" npm -g ls --depth=0

echo "---------------"
echo "Installation complete."
echo "---------------"
sleep 5   # give the UI time to start before checking
iocage exec "${JAIL_NAME}" hb-service status
#
echo "If 'Homebridge UI running' is shown above, browse to http://${IP}:${UI_PORT}"
#
echo "To later repair a broken install, from inside the jail run:"
echo "  cd /root && script homebridge-install.log ./${RESCUE_SCRIPT}"
echo "---------------"
