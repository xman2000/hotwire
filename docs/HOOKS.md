# Run your own commands

Hotwire's launcher runs two files of your own, if they exist beside it. Use them for anything your old start script did
around starting the server, such as a backup.

| File | Runs |
| --- | --- |
| `hotwire-before.bat` or `hotwire-before.sh` | Before every start, and before any update |
| `hotwire-after.bat` or `hotwire-after.sh` | After an update, whether it worked or not, and before the server starts |

Hotwire never creates or changes these files.

## Create a hook

1. In the server's folder, copy the example file from the Hotwire download:

   | Platform | Copy | To |
   | --- | --- | --- |
   | Windows | `hotwire-before.example.bat` | `hotwire-before.bat` |
   | Windows | `hotwire-after.example.bat` | `hotwire-after.bat` |
   | Linux | `hotwire-before.example.sh` | `hotwire-before.sh` |
   | Linux | `hotwire-after.example.sh` | `hotwire-after.sh` |

2. Add your commands. The examples in the file are commented out: remove the `REM` or `#` to use one.
3. Restart the server. The launcher logs `Running the before-start hook` when it runs the file.

## How a hook runs

| Behaviour | Detail |
| --- | --- |
| Folder | The server's folder |
| Process | Its own: `cmd /c` on Windows, `bash` on Linux. A variable it sets, or an `exit` in it, does not reach the launcher. |
| Waiting | The server waits until the hook finishes. Keep it quick. |
| A failure | Logged, and the server starts anyway |
| `check` | Never runs a hook |

## Tell an update from a restart (Windows)

`hotwire-before` can read `DO_UPDATE`: `1` when this start will update Rust and Oxide, `0` when it
will not. This runs one backup before an update and a lighter one on a plain restart:

```bat
@echo off
if "%DO_UPDATE%"=="1" (
    call D:\tools\backup.bat before-update
) else (
    call D:\tools\backup.bat restart
)
exit /b 0
```

On Linux, `hotwire-before.sh` reads it as `$DO_UPDATE`. Requires launcher 1.1.9-linux or later.

## Examples

Copy the plugin configs before every start, in `hotwire-before.bat`:

```bat
xcopy oxide\config D:\rust-config-copy\ /E /I /Y >nul
```

The same in `hotwire-before.sh`:

```bash
cp -a oxide/config ~/rust-config-copy/
```

Record when each update happened, in `hotwire-after.bat`:

```bat
echo %date% %time% >> updates.txt
```

## Moving from your own start script

The start-script converter lists your script's `HOOK_BEFORE` and `HOOK_AFTER` settings, if it had them, under
**Not carried**. Copy the command each one ran into the matching file above.
