# ADR-0009: Pre-flight installed-check before staging a rewind tap

**Status:** Accepted

## Context

ADR-0008 installs the rewound formula via a per-invocation tap under `$(brew --repository)/Library/Taps/brew-cooldown/homebrew-cooldown-XXXXXX/`, invoked as `brew install --force-bottle brew-cooldown/cooldown-XXXXXX/<name>`. The first real-world test of this path on a Mac surfaced a failure mode the spike missed: **brew refuses to install a same-named formula from a different tap when one is already installed.** The exact upstream error:

```
Error: pnpm was installed from the homebrew/core tap
but you are trying to install it from the brew-cooldown/cooldown-5zuxql tap.
Formulae with the same name from different taps cannot be installed at the same time.

To install this version, you must first uninstall the existing formula:
  brew uninstall pnpm
Then you can install the desired version:
  brew install brew-cooldown/cooldown-5zuxql/pnpm
```

This is brew's documented behavior — a single formula name is owned by exactly one tap at a time on a given system. Our rewind path can only put the historical version into a separate tap (per ADR-0008 the brew source rules out path-based installs at `install.rb:179`), so for any formula that's already installed from homebrew/core — which is the dominant case for an actively-maintained machine — `brew install --force-bottle brew-cooldown/...` fails. Worse, brew-cooldown's existing error suffix attributed the failure to "bottle may be unavailable; raise --days...", which is actively misleading.

## Decision

After `try_rewind` finds a candidate but before we stage the historical `.rb` or invoke brew, **pre-flight whether the formula is already installed**:

```bash
command brew list --formula --versions "$name" >/dev/null 2>&1
```

Exit 0 → installed. If installed, do not stage the tap, do not fetch the historical content, do not invoke `brew install`. Instead log a clear remediation that names the rewind candidate the user is giving up on:

```
brew-cooldown: WARN: pnpm: rewind to 05d4f8b (73d ago) is available but blocked:
  pnpm is already installed from another tap, and brew refuses overlapping
  installs across taps. To install the cooled version, run:
    brew uninstall pnpm
    brew-cooldown install pnpm
```

The formula is added to the `held[]` bucket. Behavior at the run summary level (exit code, "all packages held" message) is unchanged.

The check is run **after** `try_rewind` succeeds rather than before it, so the user sees the SHA + age of what would have been installed — that information is the value of the message; without it the user can't judge whether to bother uninstalling.

## Why not auto-uninstall + reinstall

The natural-looking shortcut would be: when blocked, automate `brew uninstall <name>` then proceed with `brew install --force-bottle <tap>/<name>`. Rejected:

- **Atomicity gap.** Between our uninstall and our install, the user has no working copy of the formula. If our `brew install --force-bottle` then fails (bottle GC'd, dep resolution change, network blip), the user is left worse off than before brew-cooldown ran — a tool whose entire purpose is risk reduction shouldn't introduce a window where the user is uninstalled and broken.
- **Trust transfer.** The currently-installed formula is owned by `homebrew/core`. Silently re-homing it to a `brew-cooldown/cooldown-XXXXXX` tap (which the user didn't ask for, and which by design doesn't persist across invocations cleanly) changes the brew metadata in ways that don't match user intent.
- **Matches the project's narrow-scope philosophy** (per [ADR-0006](0006-no-brew-intercept.md)): we don't take responsibility for state changes the user didn't explicitly request.

A future `--reinstall-via-rewind` (or similar) opt-in flag could automate the dance for users who want it, surfaced loudly and gated on explicit consent. Not in v1.

## Consequences

**Accepted positives:**

- The dominant failure mode for upgrade-of-installed-formula now produces a clear, actionable message naming the would-be rewound SHA — the user can decide whether the cooled version is worth a manual uninstall.
- No automation of destructive state changes the user didn't ask for.
- Reuses brew's own listing command rather than parsing JSON or shelling out to multiple tools.
- Pre-existing per-formula log warnings (S-21 audit line, S-16 "no N-stable" verdict) are unaffected.

**Accepted negatives:**

- One extra `brew list` invocation per held formula in a typical run. Local-only call; no network. Negligible.
- The final "all packages held; bypass with --no-cooldown if intentional" die message at the bottom of the run is still slightly misleading when *every* held formula was actually a tap-conflict (in which case `--no-cooldown` doesn't help — brew install would still hit the same conflict). The per-formula `log_warn` above the die message names the right remediation; we accept the trailing-message imprecision to avoid bucket-combinatorial die-message logic.
- Pre-flight is local to brew state, so it can race with a concurrent `brew install` in another shell. Acceptable: any race is between two installs of the same formula by the same user, which is their own problem.

## Alternatives considered

- **Auto-uninstall + install** — rejected; see "Why not auto-uninstall" above.
- **Check before `try_rewind`** — would save the commits-API call when the formula is installed, but leaves the user without the SHA + age information that lets them judge whether to uninstall. The trade-off goes the other way: one cheap API call (already budgeted, well within 5000/hr tokenized) for materially better UX.
- **Use `brew info --json=v2 <name>`** to also surface the *source* tap in the message ("installed from homebrew/core"). Same information value as our simpler message, more dependencies on JSON shape, slower. Defer until users ask for the tap name in the error.
- **Skip rewind entirely for already-installed formulae** (don't even attempt the walk-back) — sacrifices the SHA + age info as above; otherwise equivalent.
- **Add `--reinstall-via-rewind` opt-in flag now** — premature. Ship the safe, informative version first; if users ask for the automation, layer it in with explicit guardrails.
