# Install Homebridge on FreeBSD 15 or in an iocage created jail. OpenCORE (TrueNAS CORE)

A scripted install of [Homebridge](https://homebridge.io) and the Homebridge UI (homebridge-config-ui-x) in an iocage jail, run from the FreeBSD / OpenCORE. It creates the jail, installs Node.js 24 from FreeBSD packages, builds the UI's native terminal module, and installs Homebridge as a service with `hb-service` which runs as user 'homebridge'.

The Web UI is available as soon as the script finishes.

## Tested with

| Component | Version |
|---|---|
| Host | OpenCORE (FreeBSD 15.x) |
| Jail release | FreeBSD 15.1-RELEASE |
| Node.js | 24.21.0 (`node24` pkg) |
| npm | 12.0.2 (`npm-node24` pkg) |
| Python | 3.12 |
| Homebridge | 2.4.0 |
| homebridge-config-ui-x | 5.27.0 (pinned) |
| node-gyp | 13.1.0 |

Only OpenCORE on FreeBSD 15 has been tested. Previous versions ran on TrueNAS CORE 13.3 but unfortunately FreeBSD 13 pkg support has ended.

FreeBSD is not an officially supported Homebridge platform.

## Requirements

- OpenCORE (~TrueNAS CORE 15.0) or plain FreeBSD host with iocage set up, and root access
- A free static IP on your LAN for the jail
- VNET-capable bridge (defaults to `vnet0:bridge0`)

## Quick start -  There are 2 options for install. Option 1 of an iocage install with automatic jail creation. Option 2 is an install on a preexisting FreeBSD host or jail.

Option 1 :  On the host, as root:

```sh
git clone https://github.com/ssb-kod/freebsd-homebridge-iocage-install.git
cd freebsd-homebridge-iocage-install
cp homebridge-config.example homebridge-config
nano homebridge-config
chmod +x freebsd-homebridge-iocage.sh
script homebridge-iocage-install.log ./freebsd-homebridge-iocage.sh
```

`script homebridge-iocage-install.log` is optional; it saves the full output in case something fails. Keep `freebsd-homebridge-install.sh` in the same folder: the iocage script copies it into the jail as a rescue script.

When it finishes you should see `✔ Homebridge UI running.` Browse to `http://<JAIL_IP>:8581`, create your UI login, and pair with the Home app using the QR code.

Option 2 : Without iocage: existing jail or plain FreeBSD

`freebsd-homebridge-install.sh` runs the same install directly, with no jail creation. Use it inside a jail you set up yourself (VNET recommended so mDNS reaches your LAN) or on a FreeBSD 15 machine. As root, on that machine:

```sh
fetch https://raw.githubusercontent.com/ssb-kod/freebsd-homebridge-iocage-install/main/freebsd-homebridge-install.sh
chmod +x freebsd-homebridge-install.sh
script homebridge-install.log ./freebsd-homebridge-install.sh
```

It doesn't use `homebridge-config`. Optional settings go in front of the command: `UI_PORT=8080 UI_VERSION=5.27.0 HB_STORAGE=/var/lib/homebridge sh freebsd-homebridge-install.sh`. Unlike the iocage script, it doesn't touch SSH settings.

To paste it into a terminal instead, type `sh` first, paste, then type `exit` when it's done. The sub-shell keeps an error from closing your login session, since the script's error checks call `exit`.

## Disaster recovery

Updating **Homebridge UI** from the web UI currently breaks the install on FreeBSD. To repair it, rerun `freebsd-homebridge-install.sh` inside the jail. The iocage script puts a copy in the jail's `/root` for this:

```sh
iocage console homebridge
cd /root && script homebridge-install.log ./freebsd-homebridge-install.sh
```

It reinstalls Homebridge, the pinned UI version and node-pty, and reinstalls the service. Your config and HomeKit pairings in `/var/lib/homebridge` are kept. It's safe to run more than once and takes a few minutes. It doesn't read `homebridge-config`.

The log is named `homebridge-install.log` so it isn't confused with Homebridge's own `homebridge.log` in `/var/lib/homebridge`.

## Configuration (`homebridge-config`)

| Variable | Required | Default | Notes |
|---|---|---|---|
| `JAIL_IP` | yes | | `192.168.1.50/24`; netmask defaults to /24 |
| `DEFAULT_GW_IP` | yes | | Your router |
| `JAIL_NAME` | no | `homebridge` | |
| `JAIL_INTERFACES` | no | `vnet0:bridge0` | |
| `UI_PORT` | no | `8581` | |
| `UI_VERSION` | no | `5.27.0` | See [Known issues](#known-issues) |

## What the script does

1. Creates a VNET jail (`boot=on`) on the host's release (15.0 hosts get a 15.1 jail) with: `node24`, `npm-node24`, `python3`, `openssl`, `gcc`, `nss_mdns`, `ffmpeg`, `sudo`, `git`, `nano`, `mc`.
2. Creates a `homebridge` user (UID/GID 1030, no login shell) and the storage folder `/var/lib/homebridge`.
3. Enables SSH in the jail.
4. Installs `homebridge`, `node-gyp`, and `homebridge-config-ui-x@5.27.0` globally with npm.
5. Rebuilds `@homebridge/node-pty-prebuilt-multiarch` from source with `node-gyp`; no prebuilt binaries exist for FreeBSD.
6. Runs `hb-service install --user homebridge --port 8581 -U /var/lib/homebridge`, which writes `config.json`, installs the rc.d service and starts Homebridge.
7. Copies `freebsd-homebridge-install.sh` into the jail's `/root` for [disaster recovery](#disaster-recovery).

## Day-to-day

Run inside the jail (`iocage console homebridge`), or prefix with `iocage exec homebridge`:

| Task | Command |
|---|---|
| Status | `hb-service status` |
| Start / stop / restart | `hb-service start` · `hb-service stop` · `hb-service restart` |
| Logs | `hb-service logs` (or the UI) |  'cat /var/lib/homebridge/homebridge.log' if hb-service is not running
| Config and data | `/var/lib/homebridge` |

Plugins and Homebridge itself can be updated from the web UI. Don't update **Homebridge UI** there; see [Disaster recovery](#disaster-recovery).

## Known issues

- **config-ui-x is pinned to 5.27.0.** Newer versions failed the node-pty build in earlier testing. npm 12 now blocks the package's install scripts entirely, and the script's manual `node-gyp rebuild` is what actually builds the module, so newer versions may work. Test with `UI_VERSION=` in a throwaway jail before changing it.
- **Updating Homebridge UI from the web UI breaks the install.** Rerun `/root/freebsd-homebridge-install.sh` in the jail to repair it; see [Disaster recovery](#disaster-recovery).
- **Leave Node, npm and node-gyp to pkg.** `npm-node24` already provides `/usr/local/bin/node-gyp`; the script overwrites it with `npm install -g --force node-gyp`, and the next `pkg upgrade` of `npm-node24` will put pkg's version back. Don't run `npm install -g npm@…` when npm suggests it; update with `pkg upgrade`. `hb-service update-node` does not apply on FreeBSD.
- **Service account has no home folder** (`/nonexistent`, no login). If a plugin fails trying to write to `/nonexistent`, run `pw usermod homebridge -d /var/lib/homebridge` in the jail.
- **Root SSH login is enabled** for convenience. Remove `PermitRootLogin yes` from `/etc/ssh/sshd_config` after setup if you don't need it.
- **The older FreeNAS 9.10 / FreeBSD 11 guides with "service homebridge start" commands do not enable the newer 'hb-service mode' which is necessary for homebridge v2.x. installs. If these are also used this may result in multiple conflicting homebridge processes running. Also **No avahi/dbus needed:** Homebridge's default mDNS advertiser (Ciao) works in a VNET jail. Prior guides installed avahi but this crashes the UI start up and requires "pkill -f homebridge" prior to successfully starting with "hb-service start".

## Uninstall

On the host: `iocage destroy homebridge`. This deletes the jail and everything in `/var/lib/homebridge`, so back up from the UI first.

## License

MIT
