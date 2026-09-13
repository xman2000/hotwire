# A Rust server on a blank Ubuntu machine

From nothing to a running, connected server. No prior Rust experience assumed.

Roughly **45 minutes**, most of it waiting for downloads. You need **Ubuntu 22.04 or 24.04**, about
**20 GB free**, and **8 GB of RAM** as a realistic floor for a modded server.

You can stop after step 7 and have a perfectly good server; steps 8-10 add the panel, which is
optional.

> **What this never does:** nothing here, and nothing Hotwire does later, can stop your server
> starting. If the panel is slow, unreachable or gone, your server still boots and restarts. That is
> a design rule, not a hope.

> **One honest note.** Hotwire's launcher is Windows-only today, so on Linux you run the server with
> your own start script or a systemd unit — both are below — and Hotwire provides the plugin and the
> connect tooling. A Linux launcher is planned; it is not here yet.

---

## 1. A user that is not root

The game server should never run as root. This takes ten seconds and removes a whole category of bad
day.

```bash
sudo adduser --disabled-password --gecos "" rust
sudo -iu rust      # you are now the rust user; everything below runs as them
```

## 2. Swap, if you have none

Rust is memory-hungry, and an out-of-memory kill looks exactly like a crash nobody can explain.
Check first — if `free -h` already shows swap, skip this.

```bash
exit                                    # back to your admin user
free -h
sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

## 3. The clock

A drifting clock makes every signed request to the panel fail with a message that explains nothing.
Fix it now rather than debugging it later.

```bash
sudo timedatectl set-ntp true
timedatectl status        # "System clock synchronized: yes"
```

## 4. Firewall

Three ports, and **one of them must not be public**.

| port | protocol | who needs it |
|---|---|---|
| 28015 | UDP | players |
| 28017 | UDP | the server browser |
| 28016 | TCP | **RCON — you, and nobody else** |

```bash
sudo ufw allow 28015/udp comment 'Rust game'
sudo ufw allow 28017/udp comment 'Rust query'
sudo ufw allow OpenSSH
sudo ufw enable
```

**28016 is deliberately absent.** RCON is remote control of the machine. Reach it over SSH or a VPN.
If you must expose it, scope it to your own address: `sudo ufw allow from YOUR.IP.HERE to any port 28016 proto tcp`.

## 5. Install SteamCMD

Rust's server is 32-bit-linked, so the i386 architecture has to be enabled.

```bash
sudo add-apt-repository -y multiverse
sudo dpkg --add-architecture i386
sudo apt update
sudo apt install -y steamcmd lib32gcc-s1 curl jq unzip
```

The installer shows a licence prompt — accept it.

## 6. Download the Rust server

App **258550** is the dedicated server. It is free and needs no Steam account — `anonymous` is a real
login, not a placeholder.

```bash
sudo -iu rust
steamcmd +force_install_dir /home/rust/server +login anonymous +app_update 258550 validate +quit
```

About 12 GB. When it finishes you should have `/home/rust/server/RustDedicated`.

## 7. Install Oxide, and a start script

Oxide (uMod) is what lets the server run plugins. Hotwire is a plugin, so this is required to connect
to the panel later.

```bash
cd /home/rust/server
curl -fSL "https://github.com/OxideMod/Oxide.Rust/releases/latest/download/Oxide.Rust-linux.zip" -o oxide.zip
unzip -o oxide.zip && rm oxide.zip
```

That is Oxide's own release, the **Linux** build. `umod.org/games/rust/download` serves the **Windows**
build, and the two unpack to the same file names, so the wrong one cannot be spotted by looking.

Now a start script. Create `/home/rust/server/start.sh`:

```bash
#!/usr/bin/env bash
set -u
cd /home/rust/server

# Your RCON password. Long, unique, and never committed anywhere.
source /home/rust/server/secrets.env

while true; do
    ./RustDedicated -batchmode -nographics \
        +server.hostname   "Change this to your server's name" \
        +server.description "Change this to what your server is about" \
        +server.port       28015 \
        +server.queryport  28017 \
        +rcon.port         28016 \
        +rcon.password     "$RCON_PASSWORD" \
        +rcon.web          1 \
        -logfile /home/rust/server/logs/server.log

    echo "Server exited. Restarting in 10 seconds -- Ctrl-C to stop."
    sleep 10
done
```

Set the name and description to your own. Everything not on that list, including player count, map
seed, world size, how often it saves and the save folder, is left to the game's own defaults. To choose
one yourself, add it as another line, for example `+server.maxplayers 100 \`. The ports are set because
they have to match the firewall in step 4. On a machine with a second server, give that one different
ports — for example 28115, 28117 and 28116 — and open them too.

Then:

```bash
mkdir -p /home/rust/server/logs
printf 'RCON_PASSWORD="%s"\n' "$(openssl rand -base64 24)" > /home/rust/server/secrets.env
chmod 600 /home/rust/server/secrets.env
cat /home/rust/server/secrets.env      # save this in your password manager NOW
chmod +x start.sh
./start.sh
```

The first start takes several minutes — it generates the map. When your server appears in Rust's
browser under your hostname, you have a working Rust server.

**Stop here if that is all you wanted.**

### Optional: run it under systemd instead

So it starts on boot and restarts if it dies. As your admin user, create
`/etc/systemd/system/rust.service`:

```ini
[Unit]
Description=Rust dedicated server
After=network-online.target

[Service]
Type=simple
User=rust
WorkingDirectory=/home/rust/server
ExecStart=/home/rust/server/start.sh
Restart=on-failure
RestartSec=10
LimitNOFILE=65535
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now rust
sudo journalctl -u rust -f
```

**`Restart=on-failure`, not `always`.** If you later use a launcher that deliberately stops after a
crash streak, `always` would restart it immediately and defeat that protection.

---

## 8. Check the machine can talk to the panel

```bash
cd /home/rust/server
./hotwire-setup.sh doctor
```

`doctor` checks everything in one go: that this machine signs requests correctly, that it can reach
the panel, that its clock is close enough, and that it can find your server. **It writes nothing**,
so run it as often as you like.

## 9. Connect it

```bash
./hotwire-setup.sh connect
```

It tells you where to get a code and waits while you fetch it — **Servers → Connect a server** in the
panel — then asks you to paste it. You never type the code as part of a command, so it does not end
up in your shell history.

It re-checks everything `doctor` checks, shows you exactly which files it will write, and asks before
writing any of them.

## 10. Restart the server

```bash
sudo systemctl restart rust      # or Ctrl-C and ./start.sh again
```

The plugin picks up its key on load and starts reporting. Within a minute or two your server appears
in the panel with a live status.

---

## If something goes wrong

| what you see | what it means |
|---|---|
| `doctor` says the clock is too far out | `sudo timedatectl set-ntp true`, wait, try again |
| `connect` says the code is invalid or expired | codes last 60 minutes and work once — make another |
| `./RustDedicated: not found` with the file present | the i386 architecture or `lib32gcc-s1` is missing (step 5) |
| The server browser never shows your server | 28017/UDP is not open, or your provider blocks it |
| The panel shows the server but no player counts | the plugin is not loaded — check `oxide/logs/` for a compile error |

**Disconnecting** is one command and leaves everything running:

```bash
./hotwire-setup.sh detach
```
