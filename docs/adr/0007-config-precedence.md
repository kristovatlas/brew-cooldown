# ADR-0007: Config precedence and config-file format

**Status:** Accepted

## Context

`brew-cooldown` has a small config surface: cooldown days, GitHub token, fail-open flag, disable flag. Users will want to set these in different places:

- **CLI flag** — for one-off overrides (`--days 14 install wget`)
- **Env var** — for shell sessions or scripts (`export BREW_COOLDOWN_DAYS=14`)
- **Config file** — for persistent personal defaults
- **Built-in default** — when no other layer specifies

We need to define precedence and the file format. The file format choice has security implications: `source`-ing a file is a remote-code-execution vector if the file is ever attacker-writable.

## Decision

**Precedence (high → low):** CLI flag → environment variable → config file → built-in default.

**Config file location:** `${XDG_CONFIG_HOME:-$HOME/.config}/brew-cooldown/config`. (No macOS-specific fallback in v1; XDG works fine on macOS.)

**Config file format:** plain text, one `KEY=value` per line, parsed with a strict allowlist regex. Lines starting with `#` and blank lines are ignored. The file is **never** `source`d as shell.

Allowlist of recognized keys (anything else is silently ignored or, in `--debug` mode, logged as "unrecognized config key"):

- `BREW_COOLDOWN_DAYS` — must match `^[0-9]{1,4}$`
- `BREW_COOLDOWN_GITHUB_TOKEN` — must match `^[A-Za-z0-9_]{1,200}$`
- `BREW_COOLDOWN_FAIL_OPEN` — must match `^[01]$`
- `BREW_COOLDOWN_DISABLE` — must match `^[01]$`
- `BREW_COOLDOWN_DEBUG` — must match `^[01]$`

Values that don't match the per-key regex are rejected (logged in `--debug` mode); the layer falls through.

## Consequences

**Accepted positives:**

- No code execution via config file, even if an attacker can write to `~/.config/brew-cooldown/config` (e.g., a malicious dotfile-installer).
- Predictable layering: users can reason about *"where is this value coming from"* by reading the precedence rule.
- Per-key value validation gives meaningful errors on malformed config rather than mysterious behavior.

**Accepted negatives:**

- Adding a new config key requires touching the allowlist (good — forces explicit thinking) and writing a regex.
- No support for variable interpolation, conditionals, or comments mid-line. Acceptable for the size of our config surface.

## Alternatives considered

- **`source` the config file** — rejected outright: code execution. Even with `set -r`, too risky.
- **TOML / YAML / JSON** — adds parsing dependency or fragile bash code. Overkill for 5 keys.
- **Environment-only (no config file)** — too restrictive for users who want persistent defaults across shells.
- **Include the file in `.bashrc` automatically** — same RCE concerns as `source`ing.
