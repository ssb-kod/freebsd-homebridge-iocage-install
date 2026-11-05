#!/bin/sh
# Build an iocage jail on FreeCORE (TrueNAS CORE) / FreeBSD 15.x with Homebridge + Config UI X
# Node 24, node-gyp, and a rebuild of node-pty for the UI terminal.
#
# Usage (from the FreeCORE / FreeBSD 15.x host, as root):
#   script homebridge-iocage-install.log ./freebsd-homebridge-iocage.sh
# Settings such as JAIL_NAME and UI_VERSION go in homebridge-config.
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
UI_VERSION="5.30.0"      # tested: 5.30.0 and 5.27.0 work; 5.28.x/5.29.x fail on FreeBSD
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

# FreeBSD fix for node-pty 0.15+ (config-ui-x 5.28.0 and later):
# backport of https://github.com/microsoft/node-pty/pull/961
cat <<'__PATCH__' >"${JAIL_ROOT}/tmp"/freebsd-pty.patch
--- a/src/unix/pty.cc
+++ b/src/unix/pty.cc
@@ -112,7 +112,7 @@
   int exit_code = 0, signal_code = 0;
 };
 
-#if defined(__linux__)
+#if defined(__linux__) || defined(__FreeBSD__)
 
 static int
 SetCloseOnExec(int fd) {
@@ -130,8 +130,15 @@
  */
 static void
 pty_close_inherited_fds() {
+  // FreeBSD 13+ exposes close_range(2) as a plain libc function; Linux
+  // reaches the same syscall through syscall(SYS_close_range, ...).
+  #if defined(__FreeBSD__) && defined(CLOSE_RANGE_CLOEXEC)
+  if (close_range(3, ~0U, CLOSE_RANGE_CLOEXEC) == 0) {
+    return;
+  }
+  #endif
   // Try close_range() first (Linux 5.9+, glibc 2.34+)
-  #if defined(SYS_close_range) && defined(CLOSE_RANGE_CLOEXEC)
+  #if defined(__linux__) && defined(SYS_close_range) && defined(CLOSE_RANGE_CLOEXEC)
   if (syscall(SYS_close_range, 3, ~0U, CLOSE_RANGE_CLOEXEC) == 0) {
     return;
   }
__PATCH__

# Quick runtime check that node-pty can spawn a shell
cat <<'__TEST__' >"${JAIL_ROOT}/tmp"/pty-test.js
const pty = require(process.argv[2] + "/lib/index.js");
const p = pty.spawn("/bin/sh", ["-c", "echo PTY_WORKS_$((6*7))"], {
  name: "xterm-color", cols: 80, rows: 24, cwd: "/tmp", env: process.env,
});
let out = "";
p.onData(d => out += d);
p.onExit(({ exitCode }) => {
  const ok = out.includes("PTY_WORKS_42") && exitCode === 0;
  console.log(ok ? "node-pty test: OK" : "node-pty test: FAILED (" + out.trim() + ", exit " + exitCode + ")");
  process.exit(ok ? 0 : 1);
});
setTimeout(() => { console.log("node-pty test: FAILED (timeout)"); process.exit(1); }, 10000);
__TEST__

# Rebuild node-pty from source (prebuilt binaries don't exist for FreeBSD)
echo "Rebuilding node-pty-prebuilt-multiarch"
PTY_DIR="/usr/local/lib/node_modules/homebridge-config-ui-x/node_modules/@homebridge/node-pty-prebuilt-multiarch"
iocage exec "${JAIL_NAME}" /bin/sh -c "export PYTHON=/usr/local/bin/python3
  cd ${PTY_DIR} || exit 1
  if grep -q pty_close_inherited_fds src/unix/pty.cc &&
     ! grep -q 'defined(__FreeBSD__) && defined(CLOSE_RANGE_CLOEXEC)' src/unix/pty.cc; then
    echo 'Applying FreeBSD node-pty patch (microsoft/node-pty#961)'
    patch -p1 -s < /tmp/freebsd-pty.patch || echo 'WARNING: node-pty patch did not apply'
  fi
  rm -rf build && node-gyp rebuild"
iocage exec "${JAIL_NAME}" node /tmp/pty-test.js "${PTY_DIR}" || \
  echo "WARNING: UI terminal may not work; Homebridge itself is unaffected"
rm -f "${JAIL_ROOT}/tmp/freebsd-pty.patch" "${JAIL_ROOT}/tmp/pty-test.js"

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
echo "---------------"
echo "Installation complete."
echo "Testing installation..."
sleep 5   # give the UI time to start before checking
iocage exec "${JAIL_NAME}" hb-service status
#
echo "If 'Homebridge UI running' is shown above, browse to http://${IP}:${UI_PORT}"
echo "---------------"
echo "To later repair a broken installation, inside the jail run 'hb-service stop' then ..."
echo "  cd /root && script homebridge-install.log ./${RESCUE_SCRIPT}"
echo "---------------"
echo "Build info"
echo "---------------"
echo "Reminder - ssh root login enabled once root password is set in jail shell with 'passwd'. Keys are listed above and in the install log."
echo "---------------"
echo "homebridge home folder at /var/lib/homebridge/"
iocage exec "${JAIL_NAME}" ls -lah /var/lib/homebridge/
echo "---------------"
iocage exec "${JAIL_NAME}" "echo -n 'node version   ' && node --version"
echo "---------------"
echo "Global npm package lists:"
iocage exec "${JAIL_NAME}" npm -g ls
#iocage exec "${JAIL_NAME}" npm -g ls --depth=1
echo "---------------"
echo "show ffmpeg version and if fdk-aac encoder is present --> if only 'AAC (Advanced Audio Coding)' is present and not also 'Fraunhofer FDK AAC' then ffmpeg wiil work for streaming video only. If video streaming with audio is desired then ffmpeg will need to be built from ports to include 'FDK AAC'"
iocage exec "${JAIL_NAME}" "pkg info | grep ffmpeg && ffmpeg -hide_banner -encoders --version | grep aac"
echo "---------------"
echo "homebridge processes"
iocage exec "${JAIL_NAME}" "ps aux | grep homebridge"


