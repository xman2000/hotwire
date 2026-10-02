# Install a Rust server on Ubuntu

This guide installs a Rust server with Oxide and Hotwire on an Ubuntu machine, then connects it to AFKPanel. It assumes
no Rust experience.

| Requirement | Value |
| --- | --- |
| Time | About 45 minutes, most of it downloading |
| Operating system | A current Ubuntu LTS: 22.04, 24.04 or 26.04 |
| Free disk space | About 20 GB |
| Memory | 8 GB for a server with plugins |
| Access | An account with `sudo` |

The installer was tested on Ubuntu 26.04.

Steps 1 to 7 give you a working server. Steps 8 to 10 connect it to AFKPanel and are optional.

## Let the installer do it

`hotwire-setup.sh install` does every step in this guide, from SteamCMD to connecting. It checks the machine first,
shows what it will do, asks before each step, and is safe to stop and run again.

```bash
curl -fsSLO https://afkpanel.com/get/hotwire-setup.sh && sudo bash hotwire-setup.sh install
```

The script is plain bash, saved in the folder where you ran that line, so you can read it first. It:

- installs the server into `/home/rust/server`, running as a `rust` user
- uses Hotwire's launcher, a random map seed and a generated RCON password
- creates a `rust-server` service that starts with the machine (enabled, not started)
- never touches a Rust server it did not install
- records every change it makes, and how to undo it, in `hotwire/changes.log`

For a second server, add `--root /home/rust/server2`. It gets its own ports and its own service.

The rest of this guide is the same install by hand.

Nothing in this guide, and nothing Hotwire does later, can stop your server starting. If AFKPanel is slow, unreachable
or gone, the server still boots and restarts.

This guide uses a plain start script or a systemd unit, so you can see every step. Hotwire's Linux launcher,
`hotwire.sh`, replaces either one: it keeps the server running, updates Rust and Oxide, stops a crash loop, and links
`steamclient.so` for you (see step 7).

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

## 7. Install Oxide and a start script

Oxide (uMod) lets the server run plugins. Hotwire is a plugin, so you need Oxide to connect to AFKPanel.

### Install Oxide

```bash
cd /home/rust/server
curl -fSL "https://github.com/OxideMod/Oxide.Rust/releases/latest/download/Oxide.Rust-linux.zip" -o oxide.zip
unzip -o oxide.zip && rm oxide.zip
```

This is Oxide's own Linux release. `umod.org/games/rust/download` serves the Windows build, which unpacks to the same
file names, so the wrong build cannot be spotted by looking.

### Link Steam's client library

The server does not start without this link. RustDedicated loads Steam's client library from a path it does not
create. Without the link, the server generates the whole map and then stops with a `NullReferenceException` that does
not mention Steam.

As the `rust` user:

```bash
mkdir -p ~/.steam/sdk64 ~/.steam/sdk32
ln -sf ~/.local/share/Steam/steamcmd/linux64/steamclient.so ~/.steam/sdk64/steamclient.so
ln -sf ~/.local/share/Steam/steamcmd/linux32/steamclient.so ~/.steam/sdk32/steamclient.so
```

The `hotwire.sh` launcher makes this link at every start. A start script you write yourself does not.

### Write the start script

Create `/home/rust/server/start.sh`:

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

    echo "Server exited. Restarting in 10 seconds. Press Ctrl+C to stop."
    sleep 10
done
```

1. Set the name and description to your own.
2. Choose a map seed before the first start. Rust's default seed is 1337, so without one your server has the same map
   as every other server left at the default. Generate one with `shuf -i 1-2147483647 -n 1`, and add
   `+server.seed <that number> \` to the script. Keep it: a new seed on a server that has been played is a new map.
   Never put `+server.randomize_seed true` in the start script; it picks a new seed on every start.
3. Leave the ports as they are. They match the firewall in step 4. A second server on the same machine needs its own
   ports, for example 28115, 28117 and 28116; open those too.

Every setting not in the script, including player count, world size, save interval and save folder, uses the game's
default. To set one, add it as another line, for example `+server.maxplayers 100 \`.

### Start the server

```bash
mkdir -p /home/rust/server/logs
printf 'RCON_PASSWORD="%s"\n' "$(openssl rand -base64 24)" > /home/rust/server/secrets.env
chmod 600 /home/rust/server/secrets.env
cat /home/rust/server/secrets.env      # save this in your password manager
chmod +x start.sh
./start.sh
```

The first start takes several minutes while the server generates the map. When the server appears in Rust's server
browser under your name, it is working.

This is a complete server. The next steps connect it to AFKPanel.

### Optional: run the server under systemd

systemd starts the server when the machine boots and restarts it if it fails. As your admin user, create
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

Use `Restart=on-failure`, not `always`. A launcher that stops on purpose after repeated crashes would be restarted at
once by `always`, which defeats that protection.

## 8. Check that the machine can reach AFKPanel

1. Download the setup script and the plugin. The setup script runs `doctor` and `connect`; the plugin is what reports.

   ```bash
   cd /home/rust/server
   curl -fsSL https://afkpanel.com/get/hotwire-setup.sh -o hotwire-setup.sh && chmod +x hotwire-setup.sh
   mkdir -p oxide/plugins
   curl -fsSL https://afkpanel.com/get/Hotwire.cs -o oxide/plugins/Hotwire.cs
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
sudo systemctl restart rust      # or press Ctrl+C and run ./start.sh again
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
