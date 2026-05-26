# ADR-0008: Rewind to N-stable commit when the latest is held

**Status:** Accepted

## Context

ADR-0004 acknowledged that our latest-commit-date heuristic over-rejects: when a formula gets a non-version commit (bottle rebuild, dependency tweak, style fix) inside the cooldown window, we hold the install even though the underlying version is older than N days. The "right" answer of version-bump detection was deferred as a v2 refinement.

In practice this turns out to be the dominant UX complaint. The user described it as:

> *"A major obstacle to using this tool right: If an update was too recent to a project, it applies no update at all."*

Two refinement strategies were considered:

**(A) Version-bump detection.** Walk the formula's commit history; key the cooldown off the date the `version`/`url` field actually changed, not the latest commit. Rejected: it's *unsafe*. Any post-version-bump commit (bottle rebuild, patch addition, change to the `install` Ruby block) can be malicious, and version-bump detection would let it through as long as the underlying version label is N-days old. The cooldown's actual security property is "the file's current state has been the file's current state for ≥ N days," not "the version string is old."

**(B) Install a historical version of the formula.** When the latest commit is held, find an older commit that is itself eligible, stage that historical formula content, and install from it. Safe if done right; turns brew-cooldown into a tool that materializes installable artifacts on disk (a real scope expansion); but avoids the unsafety of (A).

The user accepted (B) with an explicit constraint:

> *"We definitely cannot be responsible for building projects, that would be insane. Let's just say we'll install an older version if it's available through the normal channels."*

A spike against the brew source confirmed (B) is viable:

- `Library/Homebrew/cmd/install.rb:179` declares `named_args [:formula, :cask], min: 1` — path-based install (`brew install /tmp/foo.rb`) is rejected at the argument parser. Local-tap is the only viable mechanism.
- `Library/Homebrew/formula_installer.rb:395-397` raises `CannotInstallFormulaError` when `--force-bottle` is set and no bottle is available. That gives us "no source fallback" semantics natively, contrary to the brew manpage's "prefer bottle" description.
- `Library/Homebrew/global.rb:9` defaults `HOMEBREW_BOTTLE_DEFAULT_DOMAIN` to the homebrew-core CDN, so a homebrew-core `.rb` staged verbatim into a non-core tap still resolves bottle URLs against the original content-addressed bottles.

## Decision

When the latest commit on a formula file is too fresh under the configured cooldown, **rewind to the most recent N-stable commit** and install the formula content at that commit via a per-invocation local tap with `--force-bottle`.

A commit `C` on the formula file is **N-stable** iff:

- a later commit `D` on the same file exists AND `D.committer_date − C.committer_date ≥ N days` (i.e. `C` reigned at HEAD for ≥ N days before `D` displaced it), **OR**
- `C` is the current HEAD AND `now − C.committer_date ≥ N days` (today's behavior, preserved as the single-commit case of the general rule).

The install picks the most recent N-stable commit and stages its `.rb` content into a per-invocation local tap (`mktemp -d` with `0700`, layout `<tmpdir>/Formula/<name>.rb`), then `exec`s `brew install --force-bottle <tap-ns>/<tap-name>/<formula>`. The tempdir is `trap`-cleaned at exit. If brew exits with `CannotInstallFormulaError` — formula has no `bottle do` block at all, or no entry for the user's platform tag, or the bottle blob has been GC'd from the CDN — surface that as a held-style verdict; never fall through to a source build.

Default-on. A `--no-rewind` flag and `BREW_COOLDOWN_NO_REWIND=1` env var restore the previous "hold and refuse" behavior. Walk-back is bounded by `BC_MAX_REWIND_COMMITS=30`; if no N-stable commit is found within the bound, hold with a distinct verdict ("no N-stable version found within search bound").

## Why N-stable, not "latest commit ≤ now − N days"

The simpler "rewind to the latest commit at least N days old" formulation is unsafe in the revert-inside-cooldown case:

```
day -20:  L  (last legit version)
day   0:  M  (malicious commit lands)
day   3:  R  (caught and reverted)
day   7:  user runs `brew-cooldown install <pkg>` with N=7
```

Naive rule at day 7: most recent commit with `date ≤ day 0` is `M` itself — we'd install the malicious one. Today's behavior correctly holds (latest commit `R` is age 4 < 7). The naive rewind would *regress* on a case the existing tool already handles.

N-stable rule on the same timeline: `R`'s time-as-HEAD = 4 days (not N-stable), `M`'s = 3 days (not N-stable), `L`'s = 20 days (N-stable). Pick `L`. Clean.

Intuition: the cooldown is buying us *time the version sat undisturbed at HEAD*, not *age*. They coincide for the current HEAD, which is why ADR-0004's "age ≥ N" rule works today, but for any earlier commit they diverge.

## Consequences

**Accepted positives:**

- Resolves the dominant UX complaint from ADR-0004 (over-rejection from routine non-version churn).
- Gives users an install path during the cooldown window without weakening the security property.
- Same trust primitives as today: git content-addressing of historical `.rb` content, GitHub-server-stamped `committer.date` on PR merges (threat-model non-mitigation #8), branch protection on `homebrew-core` blocking history rewrites.
- Handles malicious-then-reverted edge case correctly by construction.
- No new external services or trust surface — same GitHub API, same TLS pinning, same `commit.committer.date` field.
- "No source build, ever" is enforced by brew itself via `--force-bottle`, not by us — one fewer thing for us to police.

**Accepted negatives:**

- Brief on-disk staging of a historical `.rb` between fetch and install. Mitigated by per-invocation `mktemp -d` at `0700` with `trap` cleanup. A local attacker with write access to the tempdir could swap the file — but such an attacker already has the host and can modify the `brew` binary or the user's homebrew-core clone; not a meaningful new attack surface.
- Walking commit history costs additional GitHub API calls per held formula (pagination of the commits API plus one contents fetch for the chosen SHA). Bounded by `BC_MAX_REWIND_COMMITS`. Token mode is more strongly recommended for heavy users.
- Formulae with no bottle for the user's platform tag (rare at short cooldowns, possible at long ones, certain for formulae that predate Homebrew bottles) will be held with "older bottle no longer hosted" rather than installed. This is the price of refusing to source-build.
- Patient-attacker non-mitigation #1 is unchanged: a compromise that survives ≥ N+1 days will be installed by either today's behavior or N-stable rewind. We don't fix this, but we don't make it worse.
- Users on a formula under continuous churn (commit every few days for weeks) may see "no N-stable commit found within search bound." They can raise the bound, fall back to `--no-rewind` to see the held-with-eligibility-date message, or `--no-cooldown` if they've independently verified.

## Alternatives considered

- **Version-bump detection (ADR-0004 approach 2)** — rejected as unsafe; see Context.
- **Naive "latest commit ≤ now − N days"** — rejected as unsafe in the revert-within-cooldown case; see "Why N-stable" above.
- **`brew extract`** — rejected. Version-keyed, not commit-keyed, so it cannot distinguish a revert from its predecessor at the same version string. Also requires the local homebrew-core clone to contain the target version, which expands our dependency on local brew state.
- **Path-based install (`brew install /tmp/foo.rb`)** — rejected by brew itself at `cmd/install.rb:179`.
- **Allow source-build fallback when no bottle is available** — rejected per explicit user direction. Source-building requires us to take responsibility for the user's build toolchain and dependency resolution, and the historical formula's `install` Ruby block is itself attacker-influenceable — the very thing the cooldown is defending against. Far outside this tool's narrow scope.
- **Opt-in flag rather than default-on** — considered, rejected. The cooldown's promise — "you only install code that has had ≥ N days of passive review" — is *preserved* by N-stable rewind, not weakened. Making rewind the default makes the tool usable on popular formulae without changing the security posture. Users who prefer the stricter "hold-and-wait" behavior get `--no-rewind`.
- **Persistent local tap rather than per-invocation tempdir** — considered, rejected. A persistent tap accumulates state, complicates cleanup, and gives an attacker a stable file to target between invocations. Per-invocation `mktemp -d` is simpler, auditable, and matches the project's narrow-surface philosophy.
