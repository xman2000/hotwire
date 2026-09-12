# hotwire-connect

Connects a Rust server to [Hotwire Panel](https://hotpanel.on-forge.com), or explains why it will
not. **Optional and reversible** — your server does not need a panel to run, and `detach` leaves the
machine exactly as it was found.

```
hotwire-connect.sh doctor     # check this machine. read-only, changes nothing, safe any time
hotwire-connect.sh connect    # --code HW-XXXX-XXXX [--name "My server"]
hotwire-connect.sh status     # what this server is connected to
hotwire-connect.sh detach     # disconnect. the server keeps running
```

Requires `bash`, `curl`, `openssl`, and either `jq` or `python3`.

## Start with `doctor`

It writes nothing, and it checks the things that otherwise fail in ways nobody can diagnose:

```
Tools
  [ ok ] curl is installed
  [ ok ] openssl is installed
  [ ok ] a JSON reader is available (jq)

This server
  [ ok ] Rust server found at /home/rust/server
  [ ok ] Oxide is installed
        not connected yet (that is what 'connect' is for)

The panel
  [ ok ] panel is reachable at https://hotpanel.on-forge.com
  [ ok ] clock agrees with the panel (0s apart)
```

**The clock check is the one that earns its place.** Every request is signed with a timestamp the
panel refuses if it is more than 300 seconds out, and the refusal says only that the timestamp was
outside the window. On a fresh VM with no NTP that is every request, forever, with no clue as to why.

## What it writes, and where

Only inside your server directory, and only after asking:

| file | what |
|---|---|
| `hotwire/connect.json` | install id, panel URL, server name. No secrets. |
| `hotwire/keys.json` | the launcher's signing key. `chmod 600`. |
| `oxide/data/Hotwire/panel.json` | the plugin's signing key. `chmod 600`. |

The plugin's key is in `oxide/data/` and **not** in `oxide/config/Hotwire.json`, because the plugin
rewrites its config constantly and the documented way to reset it is to delete it — which would
quietly disconnect your server.

Anything it would replace is backed up first, with the path printed.

## Reconnecting is safe

`connect.json` holds an install id minted on first connect. Running `connect` again from the same
machine **adopts** the server the panel already has and rotates its keys, rather than creating a
second one. Renaming is free: the history follows the install, not the name.

## It never sends a file, or a config value

The panel has no endpoint that accepts a plugin's source or a configuration value — hashes and
metadata travel, contents do not. What leaves this machine about *players* is yours to choose, and
the default shares no player identity at all.
