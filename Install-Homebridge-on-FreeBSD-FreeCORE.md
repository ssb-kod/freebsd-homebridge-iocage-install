# Install Homebridge on FreeBSD 15 or in an iocage created jail. FreeCORE (TrueNAS CORE)


This guide includes 2 options to help one install Homebridge v2.x with a working Homebridge UI on freeBSD. Option 1 creates an iocage homebridge jail. Option 2 covers installing directly within an existing jail or plain FreeBSD install. Either option will result in a working homebridge install within minutes of starting the script. No additional commands are necessary.  Note Homebridge v2.x runs using `hb-service` commands.

## Option 1: Scripted iocage install from host (recommended for multiple installs)

A script that does every step below is maintained here: **https://github.com/ssb-kod/freebsd-homebridge-iocage-install**

On the FreeCORE / TrueNAS CORE host, as root:

```sh
git clone https://github.com/ssb-kod/freebsd-homebridge-iocage-install.git
cd freebsd-homebridge-iocage-install
cp homebridge-config.example homebridge-config
nano homebridge-config
chmod +x freebsd-homebridge-iocage.sh freebsd-homebridge-install.sh
script homebridge-iocage-install.log ./freebsd-homebridge-iocage.sh
```

In `homebridge-config`, set `JAIL_IP` and `DEFAULT_GW_IP` (in nano: Ctrl+O, Enter to save, Ctrl+X to exit; on plain FreeBSD use `ee`). Then go to `http://<jail ip>:8581`. The script also copies `freebsd-homebridge-install.sh` into the jail's `/root` as a rescue script (see Option 2).

***Please note "SSH access (root login enabled - tighten after setup if desired)". Don't forget to login to the jail's shell directly to create a root password via 'passwd' command to enable ssh logins into the jail. ssh root@'jail-ip' will not allow logins prior to this step although the web ui will function.

## Option 2: Install inside an existing jail or on a plain FreeBSD machine

`freebsd-homebridge-install.sh` does the same install without iocage. Use it inside a jail you created yourself (VNET recommended, so mDNS reaches your network) or directly on a FreeBSD 15 machine.

As root, inside the jail or on the machine:

```sh
fetch https://raw.githubusercontent.com/ssb-kod/freebsd-homebridge-iocage-install/main/freebsd-homebridge-install.sh
chmod +x freebsd-homebridge-install.sh
script homebridge-install.log ./freebsd-homebridge-install.sh
```

Optional settings can be passed in front of the command, for example `UI_PORT=8080 sh freebsd-homebridge-install.sh` (also `UI_VERSION` and `HB_STORAGE`).

The script:

1. Installs `node24`, `npm-node24`, `python3`, `openssl`, `gcc`, `nss_mdns`, `ffmpeg`, `sudo`, `git` and `nano` with pkg.
2. Creates the `homebridge` user (UID/GID 1030, no login shell) and `/var/lib/homebridge`.
3. Installs `homebridge`, `node-gyp` and `homebridge-config-ui-x@5.27.0` with npm. npm 12 warns that install scripts for `@homebridge/node-pty-prebuilt-multiarch` were blocked; that's expected.
4. Builds node-pty from source with `node-gyp rebuild`, since there are no prebuilt FreeBSD binaries. This is what makes the UI terminal work.
5. Runs `hb-service install --user homebridge --port 8581 -U /var/lib/homebridge`, which writes `config.json`, installs the rc.d service and starts Homebridge.

When it finishes you should see `✔ Homebridge UI running.` Go to `http://<ip>:8581`, create your UI login, then scan the QR code with the Home app (**Add Accessory**).

**Rescue / reinstall:** the same script repairs a broken install. Config and HomeKit pairings in `/var/lib/homebridge` are kept, and it's safe to run more than once. In a jail made by the iocage script it's already in `/root`:

```sh
cd /root && script homebridge-install.log ./freebsd-homebridge-install.sh
```

## Managing Homebridge

| Task | Command (inside the jail) |
|---|---|
| Status | `hb-service status` |
| Restart | `hb-service restart` |
| Stop / start | `hb-service stop` · `hb-service start` |
| Logs | `hb-service logs` |  'cat /var/lib/homebridge/homebridge.log' if hb-service is not running
| Config / storage | `/var/lib/homebridge` |

## Notes and troubleshooting

- **FreeBSD is not an officially supported platform. This guide is community maintained.
- **Last tested:** November 2026, Intel CPU FreeCORE host with a FreeBSD 15.1-RELEASE jail, Node.js 24, Homebridge 2.4.0, homebridge-config-ui-x 5.27.0. and with updated script 5.30.

- **Updating Node.js:** use `pkg upgrade` in the jail. `hb-service update-node` does not apply on FreeBSD. 
- **node-gyp conflict between pkg installed and npm installed versions may occur. The --force option of 'npm install -g --force node-gyp' fixed this to allow for a successful homebridge-config-ui-x@5.27.0  install.

- **Don't update Homebridge UI from the web UI.** which currently breaks the install on FreeBSD. If it happens, run the rescue script.

- **to find homebridge related processes ...
    root@homebridge:~ # ps aux | grep homebridge
    homebridge 81713  0.0  0.0   14204   2492  -  IsJ  18:12   0:00.00 daemon: /usr/local/lib/node_modules/homebridge-config-ui-x/dist/bin/hb-service.js[81714] (daemon)
    homebridge 81714  0.0  0.4 1156956 148352  -  SJ   18:12   0:18.45 node: hb-service (node)
    homebridge 82126  0.0  0.3 1128800 115488  -  SJ   18:12   0:07.49 node: homebridge (node)
    homebridge 82138  0.0  0.3 1124192 113396  -  SJ   18:12   0:07.22 node: homebridge: @homebridge-plugins/homebridge-camera-ffmpeg (node)
    root       94795  0.0  0.0   14260   2716  1  S+J  20:16   0:00.00 grep homebridge

- **'pkill -f homebridge' kills all of the above.

- **'npm ls' and 'npm -g' ls are usefull commands to display and confirm installs and locations. For manual installs always use the '-g' global option. If the -g is omitted the npm packages will be installed locally into the root folder where the homebridge user can not access unless root folder permissions are changed. Example ...
    root@homebridge:~ # npm ls
    /root
    └── (empty)
    
    root@homebridge:~ # npm -g ls
    /usr/local/lib
    ├── @homebridge-plugins/homebridge-camera-ffmpeg@4.1.0
    ├── corepack@0.36.0
    ├── homebridge-config-ui-x@5.27.0
    ├── homebridge@2.4.0
    ├── node-gyp@13.1.0
    └── npm@12.0.2
    
- **Backups:** use **Backup** in the UI before destroying or rebuilding the jail. Also don't forget to snapshot the jail prior to pkg updates in case of problems to allow for an easy recovery.

- **The older FreeNAS 9.10 / FreeBSD 11 guides with "service homebridge start" commands do not enable the newer 'hb-service mode' which is necessary for homebridge v2.x. installs. If these are also used this may result in multiple conflicting homebridge processes running. Also **No avahi/dbus needed:** Homebridge's default mDNS advertiser (Ciao) works in a VNET jail. Prior guides installed avahi but this crashes the UI start up and requires "pkill -f homebridge" prior to successfully starting with "hb-service start".
- **TrueNAS CORE 13.3 is untested as it would need FreeBSD 13 pkg support which unfortunately is no longer available via freebsd.org sources now that FreebBSD 13 is end of life. That said I am currently still running a legacy TrueNAS install of homebridge v1.11 and ui-x v5.24 in a freebsd 13.5 jail with a working eufy-security plugin installed via an earlier version of this script. Theoretically should work if there is a local freebsd 13 pkg repository available which could be built from cached pkg files from other jails if available.

-Credits
Iocage jail script is a highly modified but originated from an iocage Zoneminder install script obtained from "https://github.com/tschettervictor/bsd-apps".
Of course Claude and to some extent Gemini contributed to the install debugging, scripts, patching and instructions.
Good luck!
