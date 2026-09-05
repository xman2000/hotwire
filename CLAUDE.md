# CLAUDE.md — Hotwire

Scheduled restarts and updates for a Rust dedicated server: an Oxide plugin
plus the Windows launcher it drives. Public repo, MIT.

Read `HANDOFF.md` before writing code. It carries the design decisions, the
measured numbers behind them, and what is still unverified.

## Non-negotiable working rules

1. **Documentation ships in the same commit as the code.** A decision goes in
   `docs/DECISIONS.md` as an ADR when it is made, not later.
2. **Fail soft, in one specific direction.** A bug in Hotwire must never leave
   a server unable to restart, and must never restart one unannounced. Those
   two are the whole safety envelope. Everything else is cosmetic.
3. **The plugin writes a file and quits. That is all.** No spawning processes,
   no scheduled tasks, no shelling out. The flag file is the entire interface
   between the two halves, and keeping it that narrow is what makes either
   half replaceable.
4. **Never trust an entity reference across a frame.** Rust destroys entities
   constantly. Every deferred callback re-checks `entity == null ||
   entity.IsDestroyed` before touching anything.
5. **Distinguish verified from assumed game API.** `docs/GAME-API.md` holds
   what was read out of a real `Assembly-CSharp.dll` and is the source of
   truth. Anything else is assumed, tagged `// VERIFY:` in code, and listed in
   `docs/OPEN-QUESTIONS.md`. Never present assumed API as confirmed. Re-run
   `tools/` after a Rust update.
6. **Never guess a default.** This applies to the generated option list and to
   every comment in the launcher. `UNKNOWN` is an honest answer; a wrong
   default is a trap, because the entire value of an annotated launcher is
   that people trust the annotations.
7. **This repo is public and other people's servers will run it.** No secrets,
   no site-specific paths outside the config block, and no assumption that any
   particular plugin is installed.

## Scope: present options, do not decide

Do not add features that were not asked for — not as a fix for a mistake, not
as a logical consequence of a finding, not because it is obviously better.
Present the information and the options, let the user decide, then implement
the decision.

## Line endings

`.bat` is CRLF. `.py` and `.sh` are LF. Both are pinned in `.gitattributes`
and it matters: a `.bat` with LF confuses cmd.exe, and a `.sh` or `.py` with
CRLF fails on the first line under Git Bash with `$'\r': command not found`.
