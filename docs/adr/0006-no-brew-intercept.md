# ADR-0006: We do not replace or shim `brew`

**Status:** Accepted

## Context

A natural design for "wrap brew with a cooldown check" is:

```sh
alias brew='brew-cooldown'
```

…and have `brew-cooldown` pass through any subcommand it doesn't care about to the real brew. This gives users the experience of "I keep typing `brew` and the safety check happens automatically."

The user pushed back on this approach during planning:

> *"Just want to note we're not going to intercept 'brew' commands, this will be a new command. Intercepting by replacing the 'brew' command seems kinda dicey and a big responsibility."*

That's the right call for several reasons we want to record.

## Decision

`brew-cooldown` is its own command. Users invoke `brew-cooldown install <pkg>` (or `upgrade`, or `reinstall`) when they want the cooldown check. They keep using `brew` directly for everything else, including for ad-hoc installs they've decided to fast-track.

We do **not**:

- Recommend `alias brew=brew-cooldown` in our docs
- Provide a `--shim` mode that places `brew-cooldown` ahead of `brew` on PATH
- Pass-through any subcommand

We do, defensively:

- Call the real brew via `command brew` rather than `brew`, so that if a user happens to have an alias somewhere, we don't recurse into ourselves.

## Consequences

**Accepted positives:**

- We own a small, well-defined scope. Everything in our spec is something we deliberately implemented.
- We can't break the user's `brew search` flow because we never see it.
- No infinite-recursion edge case (if a user aliased anyway and we forgot `command`, the script would call itself).
- Smaller threat surface — no flag-parsing bugs leaking unintended brew invocations.

**Accepted negatives:**

- Users have to remember to type `brew-cooldown` instead of `brew`. Some won't, and they'll get no protection on those invocations. That's their conscious choice; we make the trade-off visible in the README.
- Slightly more keystrokes per protected command.

## Alternatives considered

- **Alias-based shim** — rejected per user direction; see Context.
- **PATH-prefix shim** (place `brew-cooldown` named `brew` earlier in PATH) — same problems as alias, plus: hard to uninstall cleanly, breaks scripts that resolve `brew` by absolute path.
- **`brew` plugin / external command** (`brew cooldown install wget`) — Homebrew supports external commands named `brew-foo`, but that still re-uses the brew namespace and binds us to brew's evolving CLI.

If a user *really* wants the shim, they can write their own three-line `alias brew='brew-cooldown'` plus their own pass-through wrapper. It's not our job.
