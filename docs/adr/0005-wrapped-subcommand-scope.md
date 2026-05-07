# ADR-0005: Wrapped subcommand scope — install, upgrade, reinstall

**Status:** Accepted

## Context

The user's original framing was *"a wrapper for `brew upgrade x` and `brew update`."* We had to decide which brew subcommands `brew-cooldown` should actually intercept and which to leave alone.

Two-axis decision:

- **Which subcommands carry the threat model?** Any operation that pulls and executes new formula code from `homebrew-core` — `install`, `upgrade`, `reinstall`. `update` only refreshes metadata, doesn't run formula install scripts. `search`, `info`, `list`, `outdated` are read-only.
- **How much of brew should we be responsible for?** Every wrapped command is one we own the UX for. Wrapping more = more surface area, more flag pass-through bugs, more "but `brew X` works and `brew-cooldown X` doesn't" support questions.

## Decision

Wrap exactly three subcommands:

- `install`
- `upgrade` (both `upgrade <pkg>` and bare `upgrade`)
- `reinstall`

Anything else — `update`, `search`, `info`, `list`, `outdated`, `tap`, `cleanup`, `bundle`, etc. — returns exit 1 with a `unsupported subcommand` message that points the user at the supported list and tells them to use `brew` directly.

We deliberately do **not** pass-through other subcommands. That's covered separately in [ADR-0006](0006-no-brew-intercept.md).

## Consequences

**Accepted positives:**

- Smallest viable surface area for the threat we care about.
- No silent passthrough means no surprise behavior — what `brew-cooldown` does is exactly the cooldown check.
- Easy to specify and test: every wrapped subcommand has rows in `docs/spec.md`.

**Accepted negatives:**

- Users who try `brew-cooldown info wget` get an error and have to retype as `brew info wget`. Minor friction; the error message is helpful.
- If Homebrew adds a future subcommand that pulls and runs new code (e.g., a hypothetical `brew run` that fetches and executes), we'd have to add it here. We accept reactive maintenance.

## Alternatives considered

- **Wrap only `upgrade`** (literal interpretation of user's words) — rejected: `install` carries identical risk; protecting only upgrade leaves a `brew install` hole.
- **Wrap everything that touches a formula** (including `tap`, `bundle`) — rejected: too broad for v1, too much flag-handling complexity. `tap` is its own threat (third-party taps) addressed separately via fail-closed in v1, ADR or feature in a later version.
- **Pass-through of unwrapped subcommands** — rejected: see ADR-0006. We don't take responsibility for being a generic brew front-end.
