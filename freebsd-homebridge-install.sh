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
# Optional settings go in front with env (works in sh, csh and tcsh), e.g.:
#   env UI_VERSION=5.27.0 script homebridge-install.log ./freebsd-homebridge-install.sh
#   env UI_VERSION=5.27.0 UI_PORT=8080 script homebridge-install.log ./freebsd-homebridge-install.sh
# Settings: UI_VERSION (default 5.30.0), UI_PORT (8581), HB_STORAGE (/var/lib/homebridge).
# Add -a after 'script' to append to an existing log or change log name (...-install-1.log, -2.log, etc.)

# Check for root privileges
if ! [ "$(id -u)" = 0 ]; then
  echo "This script must be run with root privileges"
  exit 1
fi

# Settings (override with environment variables)
UI_PORT="${UI_PORT:-8581}"
UI_VERSION="${UI_VERSION:-5.30.0}"   # tested: 5.30.0 and 5.27.0 work; 5.28.x/5.29.x fail on FreeBSD
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

# FreeBSD fix for node-pty 0.15+ (config-ui-x 5.28.0 and later):
# backport of https://github.com/microsoft/node-pty/pull/961
cat <<'__PATCH__' >/tmp/freebsd-pty.patch
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
cat <<'__TEST__' >/tmp/pty-test.js
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
( cd "${PTY_DIR}" || exit 1
  if grep -q pty_close_inherited_fds src/unix/pty.cc && \
     ! grep -q 'defined(__FreeBSD__) && defined(CLOSE_RANGE_CLOEXEC)' src/unix/pty.cc; then
    echo "Applying FreeBSD node-pty patch (microsoft/node-pty#961)"
    patch -p1 -s < /tmp/freebsd-pty.patch || echo "WARNING: node-pty patch did not apply"
  fi
  rm -rf build && node-gyp rebuild ) || { echo "node-pty rebuild failed"; exit 1; }
node /tmp/pty-test.js "${PTY_DIR}" || echo "WARNING: UI terminal may not work; Homebridge itself is unaffected"
rm -f /tmp/freebsd-pty.patch /tmp/pty-test.js

# Install as a service (creates rc.d script, config.json, and starts Homebridge)
hb-service install --user "${HB_USER}" --port "${UI_PORT}" -U "${HB_STORAGE}"

#####
#
# Summary
#
#####

echo "---------------"
echo "Installation complete."
echo "Testing installation..."
sleep 6   # give the UI time to start before checking
hb-service status
echo "If 'Homebridge UI running' is shown above, browse to http://<this machine's IP>:${UI_PORT}"
echo "---------------"


echo "Build info"
echo "---------------"
echo "Reminder - ssh root login enabled once root password is set in jail shell with 'passwd'. Keys are listed above and in the install log."
echo "---------------"
echo "homebridge home folder at /var/lib/homebridge/"
ls -lah /var/lib/homebridge/
echo "---------------"
echo -n "node version   " &&  node --version
echo "---------------"
echo "Global npm package lists:"
npm -g ls
#npm -g ls --depth=1
echo "---------------"
echo "show ffmpeg version and if fdk-aac encoder is present --> if only 'AAC (Advanced Audio Coding)' is present and not also 'Fraunhofer FDK AAC' then ffmpeg wiil work for streaming video only. If video streaming with audio is desired then ffmpeg will need to be built from ports to include 'FDK AAC'"
pkg info | grep ffmpeg && ffmpeg -hide_banner -encoders --version | grep aac
ps aux | grep homebridge
