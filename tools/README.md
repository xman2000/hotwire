# tools

Same approach as `a sibling plugin/tools`: read metadata out of a real
`Assembly-CSharp.dll` with pure Python, no .NET runtime and no Unity.

```sh
python3 -m venv venv && ./venv/bin/pip install dnfile
./venv/bin/python tools/convars.py <Assembly-CSharp.dll>          # TSV reference
./venv/bin/python tools/convars.py <Assembly-CSharp.dll> --bat    # launcher lines
```

`convars.py` enumerates every `[ServerVar]` in the `ConVar` namespace and
reports its name and, where the compiler stored one, its default.

**Why generate rather than hand-write.** Convars appear, change and disappear
between Rust builds. A launcher listing options that no longer exist, or
documenting defaults that have moved, is worse than one listing nothing:
someone reads the comment and believes it. The assembly on the server is the
only authority, and it is different after every force wipe. Re-run this then.

**Defaults are reported as UNKNOWN rather than guessed.** Many convars are
initialised in a static constructor rather than as a compile-time constant, so
their value is in IL, not metadata. `a sibling plugin/tools/il.py` can already read
that IL — teaching `convars.py` to use it for `.cctor` assignments is the
obvious next step and is why some defaults are blank today.

**Status: unrun.** This was written against the metadata layout
`a sibling plugin/tools/dump.py` already depends on, but has not been executed
against a real `Assembly-CSharp.dll`. Until it has, its output is unverified.
