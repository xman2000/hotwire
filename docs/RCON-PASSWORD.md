# The RCON password file

Rust does not start without an RCON password. Hotwire's launcher reads it from `hotwire-secrets.cfg`, beside
`hotwire.bat` or `hotwire.sh`. The file holds the password and nothing else.

## Create the file

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
3. Copy `hotwire-secrets.example.cfg`, from the Hotwire download, to `hotwire-secrets.cfg`. The start-script
   converter's `hotwire-settings.zip` also holds one.
4. Open `hotwire-secrets.cfg` and replace `change_me` with the password, keeping the double quotes:

   ```
   rcon.password "the-password-you-generated"
   ```

5. Linux only: make the file readable by its owner alone.

   ```bash
   chmod 600 hotwire-secrets.cfg
   ```

## Rules

| Rule | Detail |
| --- | --- |
| Length | At least 8 characters. `hotwire.rcon_password_min` in `hotwire.cfg` sets the minimum. |
| Double quotes | Required when the password has a space. No double quote inside it. |
| Example value | `change_me` is refused |
| Other lines | Comments (`#`) only. Any other setting is ignored. |

The launcher does not start while the password breaks a rule, and says which rule. A change that breaks a rule while
the launcher runs is reported, and the server starts with the last good password.

## Change the password

1. Edit `hotwire-secrets.cfg`.
2. Save the new password in your password manager.
3. Restart the server. The launcher reads the file again before every start.

Requires launcher 1.1.10-linux or later on Linux; an older Linux launcher reads the file only when `hotwire.sh` itself
is started.

## Keep it private

- Never put the password in `hotwire.cfg`. The launcher ignores `rcon.password` there.
- Never commit `hotwire-secrets.cfg` to a repository or send it to anyone.
- RCON never has to face the internet. Keep its port, 28016/TCP by default, closed.
- On Linux, the launcher warns when the file can be read by every user on the machine.
