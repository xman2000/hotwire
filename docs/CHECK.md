# Check your settings

`check` reads `hotwire.cfg` and `hotwire-secrets.cfg`, lists every problem, and says whether a normal start would
update. It does not start or update the server, run a hook, or change a file.

## Run it

In the server's folder:

| Platform | Command |
| --- | --- |
| Windows | `hotwire.bat check` |
| Linux | `./hotwire.sh check` |

Fix each problem it lists, then run it again until it lists none.

## What a clean check says

![PowerShell after hotwire.bat check on Windows, with every line clean and the server not started](https://afkpanel.com/images/docs/win-check-clean.webp)

| Line | Meaning |
| --- | --- |
| `hotwire.cfg read: every line is a setting.` | No line was ignored |
| `Options look right.` | Every setting name is in the file's own list |
| `Rust build: installed <build>, public <build>. Up to date.` | On Windows: the installed Rust matches Steam's |
| `Rust build: installed <build>, public <build> -- current.` | On Linux: the installed Rust matches Steam's |
| `a normal start would launch without updating.` | The next start skips SteamCMD and Oxide |
| `a normal start would update here.` | The next start updates Rust and Oxide first |

## Problems that stop the start

| Message | Fix |
| --- | --- |
| `No hotwire.cfg beside the launcher` | Convert your start script at https://afkpanel.com/get-started, or copy `hotwire.example.cfg` to `hotwire.cfg` |
| `hotwire.cfg has settings that would change which server this is` | Fix the lines it lists. A bad save folder, seed, world size, port or map address would open a different save. |
| `RCON is off: no hotwire-secrets.cfg` | Nothing, unless you use an RCON tool: see [The RCON password file](https://afkpanel.com/docs/rcon-password) |
| `RCON is off: hotwire-secrets.cfg sets no rcon.password.` | Nothing, unless you use an RCON tool: add the `rcon.password` line |
| `rcon.password is still the example 'change_me'.` | Set a real password |
| `rcon.password is shorter than hotwire.rcon_password_min` | Use a longer password |

## Lines that are ignored

Each is listed as `line <number>: <reason>`. The rest of the file is used.

| Reason | Fix |
| --- | --- |
| `not a setting: a name, a space, then a value` | Write the line as `name value` |
| `a value with spaces must be in double quotes` | Put the value in double quotes |
| `a quoted value must start and end with a double quote, and hold none inside` | Remove the double quote inside the value |
| `a control character in the value` | Remove it |
| `longer than 1024 characters` | Shorten the value |
| `rcon.password: belongs in hotwire-secrets.cfg, never here; ignored` | Move the password to `hotwire-secrets.cfg` |
| `<name>: not a launcher setting; ignored` | Correct the `hotwire.` name. See [hotwire.cfg](https://afkpanel.com/docs/hotwire-cfg). |
| `<name>: <rule>; the default is used` | Correct the value, or remove it to use the default |

## Warnings

| Message | Meaning |
| --- | --- |
| `<name> is not in hotwire.cfg's list of convars. Check the spelling.` | Rust ignores a name it does not know. A setting from a newer Rust build or a mod can be correct. |
| `hotwire-secrets.cfg can be read by every user on this machine. chmod 600 it.` | Linux: run `chmod 600 hotwire-secrets.cfg` |

`hotwire.check_options 0` turns off the spelling check.
