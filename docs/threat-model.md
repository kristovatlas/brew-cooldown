# brew-cooldown — threat model

`brew-cooldown` is **defense-in-depth** against a narrow but high-impact class of supply-chain attack on Homebrew. It is **not** a primary control. Read this carefully before relying on it.

## What we protect against

**The scenario:** A maintainer account or formula PR review process for `homebrew-core` (or `homebrew-cask`) is compromised. A malicious version of a popular formula is merged. Within a few hours or days, security researchers, automated scanners, or other maintainers detect the compromise and revert the formula. But anyone who ran `brew install <pkg>` or `brew upgrade <pkg>` during that window has already executed the payload (Homebrew formulae run arbitrary Ruby on install).

**Our mitigation:** Refuse `install` / `upgrade` / `reinstall` of any formula whose current version landed in `homebrew-core` (or `homebrew-cask`) less than `N` days ago. Default `N=7`. Configurable per user.

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

## Explicit non-mitigations (read this)

These are out of scope for v1. We do **not** protect against:

1. **Compromises that survive past the cooldown window.** A patient attacker who waits N+1 days before exploiting a backdoored formula defeats this control. The cooldown is one layer; you should also have endpoint detection, least privilege, etc.
2. **Compromises of the GitHub API surface itself.** If `api.github.com` is compromised or man-in-the-middled at the TLS layer (e.g., a rogue CA), we trust whatever date it returns. Fixing this requires signed Homebrew metadata, which doesn't exist as of writing.
3. **Compromises of `jq`, `curl`, `bash`, or `brew` binaries.** If your toolchain is already pwned, brew-cooldown is moot. We assume a clean baseline.
4. **Compromises that don't involve a version bump** — e.g., a malicious bottle for an unchanged formula version. The cooldown is keyed on formula-file commit date; if no commit happens, we don't see it. (Bottle signature verification is a separate, complementary control.)
5. **Third-party taps.** v1 fail-closes on `user/repo/formula` invocations with a clear message. Adding tap support per-user is v2 work.
6. **Casks installed via custom URLs / appcasts that auto-update outside of homebrew-cask.** If a cask's installer fetches arbitrary URLs at install time and the upstream server is compromised, the cask file may be stale (so we allow it) while the binary it pulls is fresh and malicious. This is a Homebrew architectural property, not something we can fix at this layer.
7. **Local privilege escalation via brew itself.** If `brew install` performs privileged operations (e.g., casks installing into `/Applications` with `osascript`), those are governed by Homebrew, not us. We pass the call through unchanged once cooldown is satisfied.

## Failure mode

**Default: fail-closed.** Network errors, rate-limit, malformed JSON, formula not found in homebrew-core → refuse the operation with exit code 2. Better to inconvenience the user than to let an unverified install through.

**Override: `BREW_COOLDOWN_FAIL_OPEN=1`** flips this. Suitable for environments that prioritize availability (CI build hosts, kiosks) where the user accepts the trade-off. Logged loudly to stderr on every fall-through.

## Bypass

**`--no-cooldown` flag** and **`BREW_COOLDOWN_DISABLE=1` env var** both fully disable the check. Both log a warning to stderr. Intended for: emergency installs the user has independently verified, scripted setups that already do their own checks.

## What success looks like

A user running `brew-cooldown upgrade` once a week is meaningfully harder to compromise via a "caught within days" formula incident than a user running `brew upgrade`. They are not invulnerable; they have just bought themselves a reaction window. That is the entire claim of this tool.
