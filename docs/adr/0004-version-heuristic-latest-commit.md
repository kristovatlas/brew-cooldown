# ADR-0004: Version heuristic — latest commit date for the formula file

**Status:** Accepted

## Context

The GitHub commits API gives us *every* commit that touched `Formula/w/wget.rb`. We need to translate that into "when did the version a user is about to install land?"

Two approaches:

1. **Latest-commit heuristic.** Take the date of the most recent commit on the file, full stop. Use that as the version's release date.
2. **Version-bump-detection heuristic.** Walk back through commits, parsing the formula at each commit to find when the `version` (or `url` containing the version string) field actually changed.

Approach 2 is more accurate but requires:

- Multiple API calls (each commit needs its file content)
- Parsing Ruby DSL syntax (or at least regex over `version "..."` / `url "...vX.Y.Z..."`)
- Handling rebases / squash commits / version-only-in-URL formulae

Approach 1 is simpler but inaccurate when a non-version commit (style fix, dependency bump, bottle rebuild) happens after a version bump:

- Version bumped → 1.5.0 on day 0
- Bottle rebuild on day 5
- User runs `brew-cooldown install wget` on day 7 with cooldown=7
- Latest commit date is day 5 (2 days ago)
- We refuse: "version too new"
- But 1.5.0 was actually released 7 days ago — we're being conservative

The conservative direction here is **safe** (over-rejects, never under-rejects). When the latest commit is older than `N` days, we know the version is *at least* `N` days old. When it's newer than `N` days, we don't know the version's true age — we play it safe and refuse.

## Decision

Use approach 1: **latest commit date for the formula file**, via a single GitHub API call.

Formally: let `T_latest` be the committer date of the most recent commit touching `Formula/{first}/{name}.rb`. The formula is **eligible** iff `now - T_latest >= N days`.

## Consequences

**Accepted positives:**

- One API call per formula (matters for `upgrade` no-args with many formulae).
- No Ruby parsing; no fragility around `version` vs `url` vs `head`.
- Correctness in the safety direction — we never let a sub-N-day version through.

**Accepted negatives:**

- Over-rejection on formulae that get frequent non-version-bump commits (popular formulae get bottle rebuilds and dep bumps regularly). Users see "held" verdicts on versions that are actually old enough.
- The error message has to be careful: we say *"latest formula commit was N days ago"*, not *"version X was released N days ago"*, because we don't actually know the latter.

## Alternatives considered

- **Approach 2 (version-bump detection)** — defer to v2 as a refinement. Will reduce false-positives meaningfully on popular formulae.
- **Use the `revision` field in `formulae.brew.sh` JSON** — that's a Homebrew-internal counter for non-version revisions; doesn't help us.
- **Combined heuristic** (latest commit, but if commit message starts with `<formula> <version>` then trust it) — adds parsing complexity for marginal gain in v1.
