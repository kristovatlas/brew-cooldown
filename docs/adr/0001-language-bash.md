# ADR-0001: Language — Bash for v1

**Status:** Accepted

## Context

`brew-cooldown` is a thin wrapper that does:

1. Argument parsing
2. One HTTPS GET per package
3. JSON parsing of one field
4. Date arithmetic
5. `exec` of the real `brew`

It must be dead-simple to install (`git clone && ./install.sh`), trivially auditable by a security-minded user, and run on macOS by default without a separate runtime.

## Decision

Implement `bin/brew-cooldown` as a single Bash 3.2-compatible script. Hard runtime dependencies: `curl`, `jq`, `bash` (3.2 is the macOS system default), `brew`. No build step.

## Consequences

**Accepted positives:**

- Zero install friction on macOS — every Homebrew user already has `bash` and `curl`. `jq` is a 1-second `brew install jq` that we make a hard dep.
- Single ~400-line file is trivially auditable. A security engineer can read it end-to-end in under 10 minutes.
- Matches the Homebrew ecosystem (Homebrew itself is implemented in Bash + Ruby).
- Easy to test with bats-core (PATH-shimmed `brew` and `curl`).

**Accepted negatives:**

- Bash error handling is verbose; we lean on `set -euo pipefail` and explicit checks.
- macOS ships Bash 3.2 (no associative arrays in some forms, no `${var,,}`, etc.). We accept this constraint and use only 3.2-compatible features.
- JSON parsing forces a `jq` dependency. We accept it for safety (no `eval`, no regex on JSON).

## Alternatives considered

- **Python 3** — clean, stdlib-only HTTP/JSON, but: macOS no longer ships Python by default in some configurations; multiple Python versions on a user's box can pick the wrong one; users have to think about venvs. Friction outweighs cleanliness for v1.
- **Go** — compiled binary, no runtime dep, but: violates the "couple hours to v1" budget; users can't quickly read the source; release pipeline complexity (cross-compile, signing, distribute via brew or releases).
- **Ruby** — natural fit for Homebrew ecosystem, but Ruby on macOS is the system Ruby (often outdated) and we'd need to manage that.
- **Rust** — same problems as Go, plus longer compile times.

We may revisit in v2 if Bash limitations become painful (e.g., concurrent fetches for `upgrade` no-args could be much faster in Go). For now, simplicity wins.
