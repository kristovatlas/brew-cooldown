# ADR-0010: Version-introduction rewind as default; N-stable demoted to opt-in

**Status:** Accepted (supersedes [ADR-0008](0008-rewind-to-n-stable-commit.md) as the default rewind rule; N-stable retained as an opt-in)

## Context

Real-world testing of [ADR-0008](0008-rewind-to-n-stable-commit.md)'s N-stable rewind on a Mac surfaced a structural problem the spike and initial test suite didn't catch. For fast-moving formulae like `pnpm` (a JavaScript package manager that releases upstream every 2–4 days), the N-stable rule rewinds *absurdly far back* — landing on pnpm 10.33.0 from **75 days ago**, even though pnpm 11.5.0 from 9 days ago is a perfectly defensible install candidate. The user surfaced the framing problem sharply:

> *"I think we've reached a silly place where we're looking for a period where devs take a break from shipping stuff. This is not where we want to be."*

The user is right. N-stable measures *time the commit was the file's HEAD unchallenged*, which on a fast-mover formula amounts to "wait for the maintainer to stop releasing." That rewards inactivity, which is the opposite of a healthy security signal — active maintenance is what catches and fixes bugs.

The user then pointed at the npm ecosystem's existing practice — `pnpm`'s own `minimumReleaseAge` config and similar mechanisms — and asked why we can't replicate that for homebrew.

**Why npm-style cooldown works in npm and how it maps to homebrew.** In npm, the install unit is `foo@1.5.0` — an immutable registry artifact pinned by content hash. `minimumReleaseAge` asks *"when was 1.5.0 first published?"* and refuses if too recent. Safe because the artifact is locked to its content at publish time. The homebrew analog of "publish event" is the git commit that first introduced a given version label in the formula file; git commits are content-addressed and immutable, so pinning to a specific commit SHA is equivalent (in mechanism) to pinning to an npm registry hash.

**Why [ADR-0008](0008-rewind-to-n-stable-commit.md) rejected version-bump detection.** ADR-0008 explicitly ruled out a "version-bump detection" approach as unsafe, but on re-examination the rejection conflated two distinct variants:

- *Unsafe variant:* install **current HEAD** if the version label is N-days old. Genuinely unsafe — any post-version-bump commit could modify the install Ruby block or bottle SHAs.
- *Safe variant we missed:* install **the specific commit that first introduced version V** if V was first introduced ≥ N days ago. That commit is git-immutable and can't be retroactively edited; pinning to it gives the same safety property as an npm registry hash pin.

This ADR adopts the safe variant.

## Decision

### The new default rule: version-introduction rewind

For each version label V that appears in the formula file's commit history:

1. Determine V's **first-introduction commit** — the earliest commit on the file where the version label is V *and* the immediately-preceding commit on the file had a different version label.
2. Determine V's **total lifetime** — the sum of all wall-clock periods during which V was the file's current version (sum of contiguous periods, since V can be introduced, displaced, and re-introduced).
3. V is **eligible** iff:
   - **(a) Cooldown gate:** V's first-introduction commit is ≥ `N` days old (default `N=7`, from `BC_DAYS`), *and*
   - **(b) Exposure-floor gate:** V's total lifetime is ≥ `M` days (default `M=1`, from `BC_MIN_LIFETIME_DAYS`).
4. Pick the **most recent eligible V** (most recent first-introduction date among eligible candidates).
5. **Install from V's latest in-V commit that is itself ≥ N days old and has a recognized message** (per the Revision below). Original intent (preserved as a safety-side-of-the-trade-off) was to pin to V's first-introduction commit; that was refined after a real-world bottle-availability failure on pnpm — see the **Revision** section at the end of this ADR for the full reasoning.

### Version-label extraction

Commit messages are the primary signal because they're cheap (already in the commits-API response — no extra fetches). The recognized patterns, in priority order:

| Pattern | Interpretation |
|---|---|
| `^<formula> <X.Y.Z...>` | Version bump — sets the file's version to `<X.Y.Z...>` |
| `^<formula>: update <X.Y.Z...> bottle\.` | Bot bottle rebuild — same version `<X.Y.Z...>`, no version change |
| anything else | Conservatively treated as introducing a "synthetic version" identifier (`unknown:<sha>`), which never matches any other commit's version and so resets the lifetime computation |

For the conservative fallback: a commit with an unrecognized message is bucketed under its own unique `unknown:<sha>` synthetic version, and the picker **explicitly skips any `unknown:*` version when iterating eligible candidates** — even if a single such commit's own HEAD-time would individually satisfy both gates. The effect is that any maintainer commit outside the standard BrewTestBot pattern is treated as if it could be malicious, and we never install from it via the default rule. Conservative direction.

A future enhancement could fall back to parsing the formula `.rb` file at each commit to extract the `version` field directly — that's a per-commit content fetch (extra API cost) and a Ruby-DSL parsing surface, deferred until evidence shows commit-message parsing is materially insufficient for real-world formulae.

### Demoting N-stable to opt-in

The [ADR-0008](0008-rewind-to-n-stable-commit.md) N-stable rule remains implemented and is available via:

- **`--strict-cooldown`** CLI flag, and
- **`BREW_COOLDOWN_STRICT=1`** environment variable.

When set, brew-cooldown uses N-stable in place of version-introduction. Users who want the stronger "this code was the file's current state for ≥ N days" claim (and are willing to accept the much-deeper rewinds for fast-movers) can opt in.

The flag composes with `--no-rewind` (ADR-0008's existing opt-out) in the obvious way: `--no-rewind` wins (no rewind at all); `--strict-cooldown` only matters when rewind is happening.

## Safety analysis

Walked through the threat scenarios that drove this design.

### Scenario A: pnpm normal case (no malicious activity)

Recent pnpm commits (BrewTestBot, every 2–4d): `11.5.2 → 11.5.1 → 11.5.0 → 11.4.0 → ...`. Each version bump is followed within ~1 hour by a bottle-rebuild commit for the same version.

- V=11.5.2: first-introduction 2d ago, fails gate (a). Skip.
- V=11.5.1: first-introduction 5d ago, fails gate (a). Skip.
- V=11.5.0: first-introduction 9d ago ✓, total lifetime ~4 days ✓. **Eligible.**
- Install from V=11.5.0's first-introduction commit (a 9d-old commit, version label `11.5.0`).

vs. ADR-0008 N-stable which picks pnpm 10.33.0 from 75 days ago. Substantially better UX for the user without changing the underlying security primitive (git immutability of the picked commit).

### Scenario B: malicious commit reverted within an hour

- Day −7: attacker lands commit M introducing `V_mal` (a previously-unseen version label)
- Day −7 + 30 min: legitimate maintainer reverts, restoring the previous version `V_legit`
- Day 0: user runs `brew-cooldown install <pkg>`

- V=`V_mal`: first-introduction 7d ago ✓, total lifetime 30 min, fails gate (b). **Not eligible.** Skip.
- V=`V_legit`: continues to qualify under its own first-introduction date (much older). **Eligible.**
- Install from `V_legit`'s first-introduction commit. Not malicious.

The exposure-floor gate (b) is what defends against this revert-within-hours pattern. Without it, V_mal would qualify under (a) alone and we'd install from M (the malicious commit). With it, M's tiny lifetime disqualifies V_mal entirely.

### Scenario C: malicious commit *within* an existing version's lifetime (spoofed bot-rebuild message)

- Day −10: legitimate `<formula> 11.5.0` commit (introduces V=11.5.0)
- Day −7: attacker lands a commit with message `<formula>: update 11.5.0 bottle.` whose actual content modifies the `install` Ruby block
- Day −6: legitimate maintainer reverts
- Day 0: user runs `brew-cooldown install <pkg>`

> **Original rule** (pre-Revision, still available via `--strict-cooldown`):
> - V=11.5.0: first-introduction 10d ago ✓, total lifetime spans the entire 10d period ✓. **Eligible.**
> - **Install from V's first-introduction commit (day −10), NOT from the attacker's day −7 commit.**
>
> Pinning the install to the first-introduction commit defended against this case: even if an attacker landed an in-lifetime modification with a spoofed bottle-rebuild message, the original, pre-attack introduction commit's bytes (git-immutable) were what we installed.
>
> **The cost** was: original bottle SHAs only. In practice, on bottle-rebuild-heavy formulae, the original bottle gets replaced on ghcr.io within hours and isn't hosted by the time the cooldown elapses — see the Revision section below.

**Under the refined rule** (post-Revision, current default):
- V=11.5.0 eligibility unchanged.
- Install commit is the LATEST in-V commit ≥ N days old. In this scenario, the attacker's day −7 commit is ≥ 7 days old, recognized as a rebuild, and within V's lifetime — **it would be selected**. This is the trade-off the Revision accepts: defense against Scenario C now relies on `homebrew-core`'s PR review process catching malicious-content commits before they age past the cooldown. If you specifically want the original first-introduction pin, use `--strict-cooldown` to switch to the ADR-0008 N-stable rule (which picks a different commit by a different rule, but is also commit-immutable and stricter on HEAD-time).

### Scenario D: patient attacker (non-mitigation #1 reaffirmed)

A malicious version `V_mal` is landed at day 0 and *not* reverted (no maintainer detection). At day 7 it satisfies both gates. We install from M.

**Unchanged from [ADR-0008](0008-rewind-to-n-stable-commit.md) and threat-model.md non-mitigation #1.** Neither rule defends against an attack that survives past the cooldown window — that's an accepted limitation of all time-based cooldown approaches.

## Consequences

**Accepted positives:**

- Fast-moving formulae no longer rewind absurdly far. Pnpm-class packages get installs from days-old commits, not months-old ones.
- The security claim *"this version label has had ≥ N days of public registry presence + ≥ M days of HEAD exposure"* maps cleanly to the existing npm-ecosystem mental model (`minimumReleaseAge`).
- Per-formula safety is robust against in-lifetime attacker modifications (step 5 pins to introduction commit).
- No additional GitHub API cost — commit-message parsing uses fields already in the commits-API response.
- N-stable users aren't disenfranchised; they explicitly opt in via `--strict-cooldown`.
- Defends against revert-within-hours attacks via the exposure-floor gate.

**Accepted negatives:**

- **Slight weakening of the security claim relative to N-stable.** A version that was at HEAD for 1.5 days (just barely satisfying gate b) gets less real-world install attention than a version that was at HEAD for 7 days. Users for whom this matters use `--strict-cooldown`.
- **Bottle availability for very old versions.** Installing from a first-introduction commit means installing the original (pre-rebuild) bottle. If the original has been GC'd from ghcr.io, install fails. Recent-but-not-current versions (days to a few months) should be fine; year-old introductions may not be. Mitigation: surfaces as a clean `CannotInstallFormulaError` per [ADR-0009](0009-preflight-installed-check.md); user can `--strict-cooldown` to fall back to N-stable (which picks a more-recent in-version commit with newer bottles) or accept the failure.
- **Commit-message parser fragility.** Relies on BrewTestBot's predictable message format (`<formula> X.Y.Z` and `<formula>: update X.Y.Z bottle.`). If those formats change, our parser misses commits and conservatively treats them as `unknown:<sha>` (never eligible). Fail-safe direction. A real-world break would surface as "no eligible version found" rather than as wrong-version installs.
- **Marginally more complex rule** to explain to users. The single-sentence description ("install the most recently introduced version that's been live for ≥ N days") is still tractable.

## Alternatives considered

- **Keep N-stable as the default; ship version-introduction as opt-in.** Considered, rejected. The dominant real-world case (popular formulae installed by the dominant user base) gets the bad outcome under N-stable. Putting the friendlier rule behind a flag means most users hit the cliff first and only discover the better option after frustration.
- **Pure version-introduction without the lifetime-floor gate (b).** Rejected — fails Scenario B (revert-within-hours). The floor is what makes the rule meaningfully different from "naïve npm-style trust the first-introduction date alone." Cheap to compute, materially safer.
- **Install from the *latest* commit during V's lifetime (rather than the earliest).** Considered for better bottle availability, rejected — fails Scenario C (in-lifetime attacker spoof). The introduction commit is the only choice that can't be retroactively touched by an attacker operating within V's lifetime.
- **Parse formula `.rb` content at each commit to extract version.** More robust than message parsing, but adds an API fetch per commit (10-100× the current cost) and a Ruby-DSL parsing surface. Deferred as a future fallback if real-world testing shows message parsing fails too often.
- **Hybrid that requires *both* version-introduction AND N-stable to be satisfied.** Effectively reduces to N-stable for fast-movers (which always fails the N-stable gate). Same UX cliff. Rejected.
- **Per-formula configurable rules.** Users could mark fast-movers explicitly. More flexible but pushes a categorization burden onto users. The default-vs-opt-in switch achieves the same effect more simply.

## Forward references

- The user-experience refinement tracked in [issue #5](https://github.com/kristovatlas/brew-cooldown/issues/5) ("informative-refusal — show smaller-N rewind alternatives") still applies under this rule: if a held formula has no eligible version even under the friendlier default, surface the ladder at smaller `N` so the user can opt into a shorter cooldown per-install.
- A future ADR could add `--reinstall-via-rewind` (auto-uninstall before installing rewound version) and/or `BREW_COOLDOWN_MIN_DAYS` (auto-relax `N` within a floor). Out of scope here.

## Revision: bottle-availability refinement (post-Mac validation)

The first real-world Mac install attempt of pnpm under this ADR's original "install from V's first-introduction commit" rule **failed** with `brew install` error:

```
==> Fetching downloads for: pnpm
Error: Couldn't find manifest matching bottle checksum.
```

Root cause: BrewTestBot's standard workflow for pnpm-class formulae is a **version-bump commit immediately (within ~1 hour) followed by a bottle-rebuild commit** that updates the `bottle do` block's SHA256s. The original bottle (with the SHAs declared in the first-introduction commit) is replaced on ghcr.io by the rebuilt bottle within hours. By the time the cooldown window elapses (≥7 days later), the **original SHAs are no longer hosted** — only the rebuilt ones are.

The original rule pinned to the first-introduction commit, which references the now-unhosted original SHAs. brew fetched the manifest expecting those SHAs and got the rebuilt one back — checksum mismatch, install fails.

The ADR's "Accepted negatives" section had anticipated this *qualitatively* ("rarely an issue at days-to-months-old introductions") but materially underestimated its **frequency**: on any actively-released formula where BrewTestBot does a post-bump rebuild (which is essentially every popular formula), this triggers the very first time someone tries to install. So "rarely" was wrong; "almost always for popular formulae" is the honest answer.

### Refined rule

For each eligible version `V`, install from the **latest in-V commit that is itself ≥ N days old** (and whose own message is recognized as either an intro or a bot-rebuild of `V`). Both gates are unchanged; only the chosen install commit moves from "earliest in V" to "latest qualifying in V."

### What this preserves

- **Cooldown claim.** The install commit is still git-immutable and still has ≥ N days of presence in the formula's history.
- **Lifetime gate (b) — Scenario B defense unchanged.** A version introduced and reverted within hours still has total lifetime < `M` and fails gate (b) regardless of which in-V commit we'd install from.
- **`unknown:*` skip.** Unrecognized-message commits remain conservatively excluded; they cannot be selected as the install commit even if one happens to fall in V's lifetime and clears `N`.

### What this trades away

- **Scenario C defense weakens.** The original rule pinned to the first-introduction commit specifically to defend against an attacker who lands a malicious commit *within V's lifetime* using a spoofed bot-rebuild message pattern. Under the refined rule, if such an attacker commit is itself ≥ N days old, it becomes the install candidate (the latest qualifying in-V commit). Defense against this case now relies on `homebrew-core`'s **PR review process** catching the malicious diff *before* it ages into the cooldown window — the same review-process trust we already implicitly rely on for the cooldown's overall claim per threat-model.md non-mitigation #8.
- **First-introduction pin no longer a property of the default.** Users who specifically want the strict pin can `--strict-cooldown` to fall back to ADR-0008 N-stable (which also picks a commit-immutable SHA, just by a different rule).

### Why we accepted this trade-off

The bottle-availability failure is a **certainty** for popular formulae (most users would hit it on first try). The Scenario C attack is **possible but requires a meaningful upstream compromise** (either compromising BrewTestBot's automation or fooling a human maintainer reviewer with a deceptive PR). On the cost/benefit axis, "the tool works on real formulae" outweighs "we have a stronger defense against a specific upstream-compromise scenario that's already partly out of our threat model."

threat-model.md's "Defenses specific to ADR-0010 default" section is updated to reflect this.
