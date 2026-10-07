# Install a Rust server on Ubuntu

This guide installs a Rust server with Oxide and Hotwire on an Ubuntu machine, then connects it to AFKPanel. It assumes
no Rust experience.

| Requirement | Value |
| --- | --- |
| Time | About 45 minutes, most of it downloading |
| Operating system | A current Ubuntu LTS: 22.04, 24.04 or 26.04 |
| Free disk space | 15 GB, on an SSD if you can |
| Memory | 12 GB free, more for a 6000 m map |
| Access | An account with `sudo` |

The disk and memory figures are Facepunch's, from [Creating a server](https://wiki.facepunch.com/rust/Creating-a-server).

The installer was tested on Ubuntu 26.04.

Steps 1 to 7 give you a working server. Steps 8 to 10 connect it to AFKPanel and are optional.

## Let the installer do it

`hotwire-setup.sh install` does every step in this guide, from SteamCMD to connecting. It checks the machine first,
shows what it will do, asks before each step, and is safe to stop and run again.

```bash
curl -fsSLO https://afkpanel.com/get/hotwire-setup.sh && sudo bash hotwire-setup.sh install
```

The script is plain bash, saved in the folder where you ran that line, so you can read it first. It:

- keeps a copy of itself at `/usr/local/sbin/hotwire-setup`, owned by root, for `doctor`, `connect`, `detach` and the
  next install

- installs the server into `/home/rust/server`, running as a `rust` user
- uses Hotwire's launcher and a random map seed, with RCON off
- creates a `rust-server` service that starts with the machine (enabled, not started)
- never touches a Rust server it did not install
- records every change it makes, and how to undo it, in `hotwire/changes.log`

For a second server, add `--root /home/rust/server2`. It gets its own ports and its own service.

The rest of this guide is the same install by hand.

Nothing in this guide, and nothing Hotwire does later, can stop your server starting. If AFKPanel is slow, unreachable
or gone, the server still boots and restarts.

The server runs under Hotwire's Linux launcher, `hotwire.sh`. It starts the server and starts it again when it exits,
installs and updates Rust and Oxide, stops a crash loop, and links `steamclient.so` (see step 7).

## 1. Create a user that is not root

Never run the game server as root.

```bash
sudo adduser --disabled-password --gecos "" rust
sudo -iu rust      # you are now the rust user; everything below runs as them
```

## 2. Add swap, if you have none

Rust uses a lot of memory, and an out-of-memory kill looks like an unexplained crash. If `free -h` already shows swap,
skip this step.

```bash
exit                                    # back to your admin user
free -h
sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

## 3. Synchronise the clock

A wrong clock makes every signed request to AFKPanel fail, with an error that does not mention the clock.

```bash
sudo timedatectl set-ntp true
timedatectl status        # "System clock synchronized: yes"
```

## 4. Open the firewall

Rust uses three ports. Open two of them. Keep RCON closed to the internet.

| Port | Protocol | Used by | Open to the internet |
| --- | --- | --- | --- |
| 28015 | UDP | Players | Yes |
| 28017 | UDP | The Steam server browser | Yes |
| 28016 | TCP | RCON | No |

```bash
sudo ufw allow 28015/udp comment 'Rust game'
sudo ufw allow 28017/udp comment 'Rust query'
sudo ufw allow OpenSSH
sudo ufw enable
```

RCON controls the server. Reach it over SSH or a VPN. If you must open it, allow only your own address:

```bash
sudo ufw allow from YOUR.IP.HERE to any port 28016 proto tcp
```

## 5. Install SteamCMD

Rust's server needs 32-bit libraries, so enable the i386 architecture.

```bash
sudo add-apt-repository -y multiverse
sudo dpkg --add-architecture i386
sudo apt update
sudo apt install -y steamcmd lib32gcc-s1 curl jq unzip zstd
```

Accept the licence prompt when the installer shows it.

## 6. Download the Rust server

The dedicated server is Steam app 258550. It is free, and `anonymous` is a real login: no Steam account is needed.

```bash
sudo -iu rust
/usr/games/steamcmd +force_install_dir /home/rust/server +login anonymous +app_update 258550 validate +quit
```

The download is about 6 GB. When it finishes, `/home/rust/server/RustDedicated` exists.

## 7. Install Hotwire

Hotwire has two parts: the launcher, `hotwire.sh`, which runs the server, and the plugin, `Hotwire.cs`, which runs
inside it. The launcher installs Oxide (uMod), which plugins need, on the first start.

As the `rust` user:

1. Download Hotwire for Linux and unpack it into the server folder:

   ```bash
   cd /home/rust/server
   curl -fsSL https://afkpanel.com/get/linux -o hotwire-linux.zip
   unzip -o hotwire-linux.zip && rm hotwire-linux.zip && chmod +x hotwire.sh
   mkdir -p oxide/plugins && mv Hotwire.cs oxide/plugins/
   ```

2. Copy the settings file and open it:

   ```bash
   cp hotwire.example.cfg hotwire.cfg
   nano hotwire.cfg
   ```

   One setting per line: a name, a space, then the value, in double quotes when it has spaces. The ones most servers
   change are at the top:

   | Setting | What it sets |
   | --- | --- |
   | `server.hostname` | The server's name in the browser |
   | `server.description` | The server's description |
   | `server.identity` | The save folder's name |
   | `server.seed` | The map |
   | `server.worldsize` | The map's size |
   | `server.port`, `server.queryport`, `rcon.port` | 28015, 28017 and 28016, matching the firewall in step 4 |

   Choose a map seed before the first start. Rust's default seed is 1337, so without one your server has the same map
   as every other server left at the default. Generate one with `shuf -i 1-2147483647 -n 1`. Keep it: a new seed on a
   server that has been played is a new map. A second server on the same machine needs its own ports, for example
   28115, 28117 and 28116; open those too.

3. Hotwire does not need RCON, and without a password the server starts with RCON off. If you use an RCON tool, set
   one: see [The RCON password file](https://afkpanel.com/docs/rcon-password).

4. Check the settings, then start the server:

   ```bash
   ./hotwire.sh check
   ./hotwire.sh
   ```

   `check` reads every setting and says what it would do, and starts nothing. The first start installs Oxide, links
   Steam's client library and takes several minutes while the server generates the map. When the server appears in
   Rust's server browser under your name, it is working. Press Ctrl+C to stop it.

Your own commands, such as a backup before every start, go in `hotwire-before.sh` and `hotwire-after.sh`, beside
`hotwire.sh`. The download has an example of each.

### Run the server under systemd

systemd starts the server when the machine boots. As your admin user, create
`/etc/systemd/system/rust-server.service`:

```ini
[Unit]
Description=Rust dedicated server (/home/rust/server)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=rust
WorkingDirectory=/home/rust/server
ExecStart=/home/rust/server/hotwire.sh
Restart=on-failure
RestartSec=10
KillMode=mixed
TimeoutStopSec=120
LimitNOFILE=65535
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now rust-server
sudo journalctl -u rust-server -f
```

`WorkingDirectory` is required: the server looks for its files in the folder it was started from. Use
`Restart=on-failure`, not `always`. The launcher stops on purpose after repeated crashes, and `always` would start it
again at once.

`KillMode=mixed` and `TimeoutStopSec=120` let a stop or a reboot save the world: systemd asks the launcher, the
launcher asks Hotwire, and Rust saves and quits. Without them systemd stops Rust directly and the play since the last
save is lost.

## 8. Check that the machine can reach AFKPanel

1. Download the setup script. It runs `doctor` and `connect`; the plugin you installed in step 7 is what reports.

   ```bash
   cd /home/rust/server
   curl -fsSL https://afkpanel.com/get/hotwire-setup.sh -o hotwire-setup.sh && chmod +x hotwire-setup.sh
   ```

2. Run `doctor`:

   ```bash
   ./hotwire-setup.sh doctor
   ```

`doctor` checks that the machine signs requests correctly, that it can reach AFKPanel, that its clock is accurate
enough, and that it can find your server. It changes nothing, so you can run it at any time.

## 9. Connect the server

1. Run `connect`:

   ```bash
   ./hotwire-setup.sh connect
   ```

2. In AFKPanel, select **Connect a server** and copy the connect code.
3. Paste the code when `connect` asks for it. The code is not part of the command, so it stays out of your shell
   history.

`connect` repeats the `doctor` checks, lists the files it will write, and asks before writing them.

## 10. Restart the server

```bash
sudo systemctl restart rust-server      # or press Ctrl+C and run ./hotwire.sh again
```

The plugin loads its key and starts reporting. The server appears in AFKPanel within about 2 minutes.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `doctor` says the clock is too far out | The clock has drifted | Repeat step 3, wait, then run `doctor` again |
| `connect` says the code is invalid or expired | A code works for 60 minutes, once | Make a new code |
| The server fails with "not found", but `RustDedicated` exists | The i386 architecture or `lib32gcc-s1` is missing | Repeat step 5 |
| The server never appears in the server browser | Port 28017/UDP is closed, or your provider blocks it | Open the port, or ask your provider |
| The server is in AFKPanel but shows no player counts | The plugin is not loaded | Look in `oxide/logs/` for a compile error |
| The console says Steam no longer serves the installed Rust build's file list | The server was on an old build, and the machine's SteamCMD no longer has that build's file list | Nothing: the launcher updates without it. Launcher 1.1.7-linux or later. |

## Disconnect the server

```bash
./hotwire-setup.sh detach
```

The server keeps running.
