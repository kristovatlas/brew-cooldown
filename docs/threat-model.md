# brew-cooldown — threat model

`brew-cooldown` is **defense-in-depth** against a narrow but high-impact class of supply-chain attack on Homebrew. It is **not** a primary control. Read this carefully before relying on it.

## What we protect against

**The scenario:** A maintainer account or formula PR review process for `homebrew-core` (or `homebrew-cask`) is compromised. A malicious version of a popular formula is merged. Within a few hours or days, security researchers, automated scanners, or other maintainers detect the compromise and revert the formula. But anyone who ran `brew install <pkg>` or `brew upgrade <pkg>` during that window has already executed the payload (Homebrew formulae run arbitrary Ruby on install).

**Our mitigation:** Refuse `install` / `upgrade` / `reinstall` of any formula whose current version landed in `homebrew-core` (or `homebrew-cask`) less than `N` days ago. Default `N=7`. Configurable per user. When the current version doesn't satisfy the cooldown, brew-cooldown can rewind to an older eligible version — by default per [ADR-0010](adr/0010-version-introduction-rewind.md) (version-introduction), or per [ADR-0008](adr/0008-rewind-to-n-stable-commit.md) (N-stable) when `--strict-cooldown` is set.

**Why this works (probabilistically):** The most damaging public Homebrew supply-chain incidents have historically been caught and reverted within hours to a few days. Our window is calibrated to be longer than the typical detection-and-revert cycle, while short enough that legitimate fast-moving formulae aren't held back too long.

## STRIDE-lite walkthrough

| Threat | How brew-cooldown handles it |
|---|---|
| **Spoofing** of GitHub | `curl` uses TLS with system trust store; no `--insecure`; URL pinned to literal `https://api.github.com/repos/Homebrew/...`. |
| **Tampering** with API response | JSON parsed strictly with `jq` from a single, pinned shape; no `eval`. Config file is **allowlist-parsed line by line**, never `source`d. |
| **Repudiation** | Every cooldown decision is logged to stderr with formula name, latest-commit ISO date, computed age, and verdict. Not security-critical; audit-friendly. |
| **Information disclosure** | GitHub token is never logged, never printed. `mask_token` redacts token-shaped substrings on any path that might echo curl headers. `set -x` is never enabled in shipped code. |
| **Denial of Service** | One commits-API call per formula; in-memory cache for the duration of a `upgrade` no-args run (so `upgrade` of N outdated packages costs N requests, not N²). Unauthenticated GitHub limit is 60/hr; with `BREW_COOLDOWN_GITHUB_TOKEN` it's 5000/hr. We surface a distinct error message on rate-limit hits. |
| **Elevation of privilege** | `install.sh` never runs as root; symlinks into a user-writable PATH dir by default. `brew-cooldown` itself never `sudo`s. Refuses to overwrite an unrelated existing `brew-cooldown` binary without `--force`. |

## On-disk staging (shared by both rewind rules)

Both rewind rules — the default version-introduction rule per [ADR-0010](adr/0010-version-introduction-rewind.md) and the opt-in N-stable rule per [ADR-0008](adr/0008-rewind-to-n-stable-commit.md) — share the same on-disk staging mechanism: fetch the chosen historical `.rb` from GitHub, write it into a per-invocation local tap, and `exec`/`spawn` `brew install --force-bottle <tap>/<name>`. The properties of that brief on-disk window:

- **Per-invocation tempdir at `0700`.** The staging directory is created with `mktemp -d` (mode `0700` enforced); a `trap` removes it on exit (success or failure). No persistent state survives between invocations, so an attacker cannot leave a poisoned file in place for the next run.
- **Content is what we wrote.** The `.rb` is the GitHub-served content at a specific commit SHA we chose; we don't re-read user-controlled files or accept piped input.
- **A local attacker with write access to the tempdir could substitute the file** between our write and brew's read. But such an attacker can already substitute the `brew` binary itself, the user's `homebrew-core` clone, or `LD_PRELOAD` into our process — we don't add meaningful new surface relative to those baseline assumptions.
- **`--force-bottle` enforces no-source-build at brew's layer.** `Library/Homebrew/formula_installer.rb:395-397` raises `CannotInstallFormulaError` when the flag is passed and no bottle is available, so we cannot accidentally trigger a build-from-source by staging a formula whose bottle has been GC'd.

## Rewind rule selection (ADR-0010 default vs ADR-0008 opt-in)

brew-cooldown supports two rewind rules with different security/freshness trade-offs:

- **[ADR-0010](adr/0010-version-introduction-rewind.md) version-introduction (default).** Picks the most recent version label `V` where `V`'s first-introduction commit is ≥ `N` days old **and** `V`'s total lifetime as the file's version is ≥ `M` days (default `M=1`). Installs from `V`'s *first-introduction* commit (the earliest in-V commit), not from any later same-version commit. Maps to npm's `minimumReleaseAge` semantics.
- **[ADR-0008](adr/0008-rewind-to-n-stable-commit.md) N-stable (opt-in via `--strict-cooldown` / `BREW_COOLDOWN_STRICT=1`).** Picks the most recent commit `C` where `C` was the file's HEAD for ≥ `N` days unchallenged (the next-later commit is ≥ `N` days after `C`, or `C` is HEAD with age ≥ `N`). Requires longer continuous HEAD-time but doesn't depend on commit-message parsing.

**Defenses specific to the ADR-0010 default:**

1. **Pinning to the first-introduction commit defends against in-lifetime spoofed-rebuild attacks.** If an attacker lands a commit *within* a legitimate version's lifetime with a spoofed bot-rebuild message (`<formula>: update X.Y.Z bottle.` containing malicious `.rb` bytes), the rule still installs from `V`'s earliest in-V commit (which predates the attack and is git-immutable). The attacker's commit is never selected even though its message pattern matches and it falls within `V`'s lifetime. See ADR-0010 Scenario C.
2. **Lifetime-floor gate (`M`, default 1 day) defends against revert-within-hours.** A malicious version introduced and reverted within hours has total lifetime < `M` and fails the gate; we don't install from its introduction commit even once the `N`-day cooldown elapses. See ADR-0010 Scenario B.

**Trade-offs accepted by the ADR-0010 default (relative to N-stable):**

1. **Weaker HEAD-exposure claim.** N-stable requires the picked commit to have been HEAD for ≥ `N` days; the version-introduction rule only requires the *version* to have had ≥ `M` days at HEAD (default `M=1`, much weaker than `N=7`). Users for whom the stronger claim matters use `--strict-cooldown`.
2. **Bottle-availability for older introductions.** Installing from the *first*-introduction commit uses the *original* bottle SHAs declared in that commit, not later rebuilds. For recent introductions (days to a few months) this is rarely an issue; older introductions may hit `CannotInstallFormulaError` if the original bottles have been GC'd. Falling back to `--strict-cooldown` often picks a later in-version commit with still-hosted bottles.
3. **Dependence on BrewTestBot commit-message format.** The version-introduction rule parses commit messages (`<formula> X.Y.Z`, `<formula>: update X.Y.Z bottle.`) to extract version labels. If Homebrew changes its conventions or a maintainer commits with a non-standard message, our parser conservatively buckets the affected commit as `unknown:<sha>` (each such commit becomes its own synthetic version and never accumulates enough lifetime to qualify). **This is fail-closed** — we hold formulae we'd otherwise rewind rather than installing the wrong thing — but it means our default behavior depends on Homebrew's upstream conventions remaining stable. `--strict-cooldown` is the escape hatch when that bites.

## Explicit non-mitigations (read this)

These are out of scope for v1. We do **not** protect against:

1. **Compromises that survive past the cooldown window.** A patient attacker who waits N+1 days before exploiting a backdoored formula defeats this control. The cooldown is one layer; you should also have endpoint detection, least privilege, etc. **This applies to both rewind rules** — under [ADR-0010](adr/0010-version-introduction-rewind.md) (default), a version whose first-introduction is ≥ N days old and whose lifetime cleared the floor gets installed; under [ADR-0008](adr/0008-rewind-to-n-stable-commit.md) (`--strict-cooldown`), a commit that was the file's HEAD for ≥ N days unchallenged gets installed. Either way, whether the survival was genuine settling or a successful patient attack is something we cannot distinguish from outside.
2. **Compromises of the GitHub API surface itself.** If `api.github.com` is compromised or man-in-the-middled at the TLS layer (e.g., a rogue CA), we trust whatever date it returns. Fixing this requires signed Homebrew metadata, which doesn't exist as of writing.
3. **Compromises of `jq`, `curl`, `bash`, or `brew` binaries.** If your toolchain is already pwned, brew-cooldown is moot. We assume a clean baseline.
4. **Compromises that don't involve a version bump** — e.g., a malicious bottle for an unchanged formula version. The cooldown is keyed on formula-file commit date; if no commit happens, we don't see it. (Bottle signature verification is a separate, complementary control.)
5. **Third-party taps.** v1 fail-closes on `user/repo/formula` invocations with a clear message. Adding tap support per-user is v2 work.
6. **Casks installed via custom URLs / appcasts that auto-update outside of homebrew-cask.** If a cask's installer fetches arbitrary URLs at install time and the upstream server is compromised, the cask file may be stale (so we allow it) while the binary it pulls is fresh and malicious. This is a Homebrew architectural property, not something we can fix at this layer.
7. **Local privilege escalation via brew itself.** If `brew install` performs privileged operations (e.g., casks installing into `/Applications` with `osascript`), those are governed by Homebrew, not us. We pass the call through unchanged once cooldown is satisfied.
8. **`commit.committer.date` trustworthiness depends on Homebrew's upstream merge policy.** Git committer/author timestamps are user-controlled at commit creation time (`GIT_COMMITTER_DATE`, `GIT_AUTHOR_DATE`). We rely on the fact that `Homebrew/homebrew-core` and `Homebrew/homebrew-cask` accept changes only through pull requests merged via squash or rebase, which causes GitHub to set the committer date at merge time on the server side — not from the contributor's commit object. A contributor cannot forge `committer.date` through the normal PR flow. *If* the upstream merge policy ever switches to merge-commit (which preserves contributor-supplied dates), *or if* an attacker gains direct-push access to `main` bypassing branch protection (admin-level compromise, not just a compromised contributor or maintainer), the committer date becomes forgeable and the cooldown is bypassable. We accept this dependency on Homebrew's policy. See [`adr/0002-data-source-github-commits.md`](adr/0002-data-source-github-commits.md) for why we use `committer.date` rather than `author.date`. A v2 enhancement would cross-reference the PR's GitHub-stamped `merged_at` for an additional non-forgeable signal.
9. **Time-of-check / time-of-use (TOCTOU) gap between the API check and `brew install`.** brew-cooldown reads `homebrew-core`'s latest commit for a formula via the GitHub API, then `exec`s `brew install` / `upgrade` / `reinstall`. Two small windows exist between those operations: (a) sub-second wall-clock time during which an upstream formula commit could land and not be reflected in our just-fetched response, and (b) drift between the user's local homebrew-core checkout (if Homebrew has cloned it) and `main`. (a) is not exploitable by an external adversary in any practical sense — it requires sub-second precision of a malicious push timed against a specific user's CLI invocation. (b) is more interesting: a user who hasn't run `brew update` recently may install an older locally-cached version than the one we just checked. Users with strict requirements should run `brew update` immediately before invoking brew-cooldown to align local state with `main`. We deliberately do not run `brew update` ourselves because that would expand brew-cooldown's responsibility surface (see [ADR-0006](adr/0006-no-brew-intercept.md)). A v2 `--brew-update-first` flag is tracked as a follow-up. Note that on the rewind path ([ADR-0008](adr/0008-rewind-to-n-stable-commit.md)) the (b) window is closed for the rewound version specifically — we stage the historical `.rb` directly from GitHub at a known SHA and brew installs from our tap, not from the user's possibly-stale local clone.

10. **Bottle availability changes outside our control.** Both rewind rules pick a historical formula commit and ask brew to install via `--force-bottle`. If the bottle blob for the chosen commit has been GC'd from `ghcr.io` / Homebrew's CDN, brew refuses with `CannotInstallFormulaError` and the user sees a held verdict. **This is by design**: we explicitly choose unavailability over a source-build, because the historical formula's `install` Ruby block is itself attacker-influenceable — the very thing the cooldown is defending against. The ADR-0010 default is *more likely* to encounter this than ADR-0008 N-stable because it pins to the *first*-introduction commit (oldest in-version commit, with the original bottle SHAs) rather than to a later in-V or N-stable commit whose bottles are more likely to still be hosted. Users who hit this can fall back to `--strict-cooldown` (often picks a later commit with hosted bottles), `--no-rewind` (held with eligibility date for the latest), `--no-cooldown` (if independently verified), or use `brew install` directly.

## Failure mode

**Default: fail-closed.** Network errors, rate-limit, malformed JSON, formula not found in homebrew-core → refuse the operation with exit code 2. Better to inconvenience the user than to let an unverified install through.

**Override: `BREW_COOLDOWN_FAIL_OPEN=1`** flips this. Suitable for environments that prioritize availability (CI build hosts, kiosks) where the user accepts the trade-off. Logged loudly to stderr on every fall-through.

## Bypass

**`--no-cooldown` flag** and **`BREW_COOLDOWN_DISABLE=1` env var** both fully disable the check. Both log a warning to stderr. Intended for: emergency installs the user has independently verified, scripted setups that already do their own checks.

## What success looks like

A user running `brew-cooldown upgrade` once a week is meaningfully harder to compromise via a "caught within days" formula incident than a user running `brew upgrade`. They are not invulnerable; they have just bought themselves a reaction window. That is the entire claim of this tool.
