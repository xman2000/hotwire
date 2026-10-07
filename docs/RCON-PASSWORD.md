# The RCON password file

RCON is remote control of a Rust server: an RCON tool, such as RustAdmin or BattleMetrics, sends console commands with
a password. Hotwire does not use RCON. Without a password, Rust starts with RCON off, and nothing can connect to it.

Requires launcher 1.1.27 or later on Windows, and 1.1.12-linux or later on Linux. Older launchers do not start without
a password.

## Turn RCON on

Only if you use an RCON tool.

1. Generate a long, unique password.

   Windows, in PowerShell. This copies it to your clipboard:

   ```powershell
   -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 |
     ForEach-Object { [char]$_ }) | Set-Clipboard
   ```

   Linux:

   ```bash
   openssl rand -base64 24
   ```
2. Save the password in your password manager.
3. Copy `hotwire-secrets.example.cfg`, from the `examples` folder of the Hotwire download, to `hotwire-secrets.cfg`, beside `hotwire.bat` or
   `hotwire.sh`. The start-script converter's `hotwire-settings.zip` also holds one.
4. Open `hotwire-secrets.cfg`, remove the `#` before `rcon.password`, and replace `change_me` with the password,
   keeping the double quotes:

   ```
   rcon.password "the-password-you-generated"
   ```

5. Linux only: make the file readable by its owner alone.

   ```bash
   chmod 600 hotwire-secrets.cfg
   ```

6. Restart the server. The launcher reads the file again before every start.

## Only from this machine

If every RCON tool you use runs on the server's own machine, RCON can listen there only. Nothing elsewhere can reach
it, even with its port open in a firewall. Tools on other machines, such as BattleMetrics or RustAdmin on your own
computer, then cannot connect.

1. In `hotwire.cfg`, set:

   ```
   rcon.ip                     127.0.0.1
   ```

2. Restart the server.

To undo it, remove the line and restart. `hotwire-setup` offers this when it finds an RCON password.

## Turn RCON off

Delete the `rcon.password` line, or the whole file, and restart the server.

## Rules

| Rule | Detail |
| --- | --- |
| Length | At least 8 characters. `hotwire.rcon_password_min` in `hotwire.cfg` sets the minimum. |
| Double quotes | Required when the password has a space. No double quote inside it. |
| Example value | `change_me` is refused |
| Other lines | Comments (`#`) only. Any other setting is ignored. |

A password that breaks a rule never stops the server. The launcher says which rule, and starts with the last good
password, or with RCON off if there was none.

## Keep it private

- Never put the password in `hotwire.cfg`. The launcher ignores `rcon.password` there.
- Never commit `hotwire-secrets.cfg` to a repository or send it to anyone.
- RCON never has to face the internet. Keep its port, 28016/TCP by default, closed, unless a tool outside the machine
  needs it.
- On Linux, the launcher warns when the file can be read by every user on the machine.
