# brew-cooldown — behavior spec

This is the source of truth for what `brew-cooldown` does. Every row is paired with a bats test under `tests/integration/` (or `tests/unit/` for pure-function rows). If a row fails its test in CI, the build is red. If you change behavior, **update this table first**, then the tests, then the code.

## Wrapped subcommands

`brew-cooldown` only wraps three brew subcommands. Anything else is rejected with exit 1 and a usage message.

| Wrapped | Pass-through? | Why |
|---|---|---|
| `install <pkg>` | After cooldown OK *or* after rewind to last N-stable | Same supply-chain risk as upgrade |
| `upgrade <pkg>` / `upgrade` | After cooldown OK *or* after rewind to last N-stable (no-args = partial upgrade) | The motivating threat |
| `reinstall <pkg>` | After cooldown OK *or* after rewind to last N-stable | Reinstalls re-pull the latest formula |
| `update`, `search`, `info`, anything else | **No** — exit 1 | We don't take responsibility for shimming `brew` |

## Configuration precedence

`CLI flag > env var > config file > built-in default.`

| Setting | Default | Env var | CLI flag |
|---|---|---|---|
| Cooldown days | `7` | `BREW_COOLDOWN_DAYS` | `--days N` |
| GitHub token | (none) | `BREW_COOLDOWN_GITHUB_TOKEN` (also `HOMEBREW_GITHUB_API_TOKEN`) | — |
| Fail open on errors | `0` (closed) | `BREW_COOLDOWN_FAIL_OPEN` | — |
| Disable cooldown | `0` | `BREW_COOLDOWN_DISABLE` | `--no-cooldown` |
| Cask | (formula) | — | `--cask` |
| Dry run | off | — | `--dry-run` |
| Debug log | off | `BREW_COOLDOWN_DEBUG` | `--debug` |
| Disable rewind (opt-out) | `0` (rewind enabled) | `BREW_COOLDOWN_NO_REWIND` | `--no-rewind` |
| Max rewind commits | `30` | `BREW_COOLDOWN_MAX_REWIND_COMMITS` | — |

## Behavior table (objective)

| ID | Given | When | Then |
|---|---|---|---|
| **S-01** | formula `wget`, latest commit 90d ago, days=7 | `brew-cooldown install wget` | exec `brew install wget`, exit 0 |
| **S-02** | formula `wget`, latest commit 1d ago, days=7 | `brew-cooldown upgrade wget` | exit 1; stderr contains `held` and an ISO eligibility date |
| **S-03** | 3 outdated formulae: 2 eligible (90d), 1 held (1d) | `brew-cooldown upgrade` (no args) | exec `brew upgrade <eligible1> <eligible2>`; stderr summary lists the held one with eligibility date |
| **S-04** | curl exits non-zero (network failure) | `brew-cooldown install wget` | exit 2; stderr contains `fail-closed` and the underlying reason; `brew` is **not** invoked |
| **S-04b** | same as S-04 + `BREW_COOLDOWN_FAIL_OPEN=1` | `brew-cooldown install wget` | warn to stderr, then exec `brew install wget` |
| **S-05** | name `wget; rm -rf /` (or any input failing the regex) | `brew-cooldown install 'wget; rm -rf /'` | exit 1; stderr contains `invalid name`; **no** curl call, **no** brew call |
| **S-06** | `--no-cooldown install wget` (latest commit 1d ago) | — | warn to stderr, then exec `brew install wget` |
| **S-07** | `brew-cooldown search wget` (unsupported subcommand) | — | exit 1; stderr lists supported subcommands; **no** curl call, **no** brew call |
| **S-08** | `--dry-run upgrade wget` (eligible) | — | stdout prints `brew upgrade wget`; exit 0; **no** brew exec |
| **S-09** | cask `firefox`, latest commit 3d ago, days=7 | `brew-cooldown install --cask firefox` | exit 1; held (cask path used: `Casks/f/firefox.rb` in `Homebrew/homebrew-cask`) |
| **S-09b** | font cask `font-fira-code`, latest commit 30d ago | `brew-cooldown install --cask font-fira-code` | exec `brew install --cask font-fira-code` (cask path: `Casks/font/font-fira-code.rb`) |
| **S-10** | GitHub returns rate-limit JSON `{"message":"API rate limit exceeded ..."}` | `brew-cooldown install <any>` | exit 2; stderr contains `rate limit` and a hint to set `BREW_COOLDOWN_GITHUB_TOKEN` |
| **S-11** | config file sets `BREW_COOLDOWN_DAYS=14`; env var sets `BREW_COOLDOWN_DAYS=3`; flag sets `--days 1` | `brew-cooldown install <fresh-formula>` (latest commit 2d ago) | exec `brew install ...` (because flag wins, 2 ≥ 1) |
| **S-12** | config file containing a malicious line like `BREW_COOLDOWN_DAYS=7; rm -rf /` | `brew-cooldown install wget` | line is rejected (not parsed); falls back to next layer (env or default); `rm` is never invoked |
| **S-13** | third-party tap requested (`some-user/tap`) — out of v1 scope | `brew-cooldown install some-user/tap/foo` | exit 1; stderr `third-party taps not supported in v1; use brew directly or wait for a future release` |
| **S-14** | formula `wget`, HEAD commit 3d ago (not N-stable), prior commit 12d ago (gap 9d ≥ 7), days=7 | `brew-cooldown install wget` | stage prior commit's `.rb` into a per-invocation tap dir; exec `brew install --force-bottle <tap-ns>/<name>/wget`; stderr logs the rewound commit SHA, its age in days, and its ISO committer date |
| **S-15** | formula `wget`, commit history HEAD=revert 4d ago, prior=malicious 7d ago, prior-prior=legit 27d ago, days=7 | `brew-cooldown install wget` | rewind picks the legit 27d-old commit (not the 7d-old "malicious" one); staged `.rb` content equals the legit commit's content; assert the test harness never sees the malicious commit's content materialized |
| **S-16** | 30 commits all within last 7d (continuous churn, none N-stable), days=7, `BREW_COOLDOWN_MAX_REWIND_COMMITS=30` | `brew-cooldown install <pkg>` | exit 1; stderr `no N-stable version found within last 30 commits; raise BREW_COOLDOWN_MAX_REWIND_COMMITS, use --no-rewind for eligibility date, or --no-cooldown to bypass`; **no** brew exec |
| **S-17** | rewind picks N-stable commit C; shimmed brew exits non-zero (simulating missing bottle for user's platform) | `brew-cooldown install wget` | brew is invoked with `install --force-bottle <tap>/wget`; brew-cooldown exits with brew's exit code; **no** source-build is attempted (asserted by the absence of `--build-from-source` in brew's argv and by `--force-bottle` being present) |
| **S-18** | latest commit 3d ago, N-stable predecessor exists, days=7, `--no-rewind` set | `brew-cooldown install wget` | exit 1; stderr lists the held verdict with eligibility ISO date (today's pre-ADR-0008 behavior); **no** brew exec, **no** staging |
| **S-19** | `BREW_COOLDOWN_NO_REWIND=1` set via env (no CLI flag) | same scenario as S-18 | identical behavior to S-18 — env var matches CLI flag (config-precedence smoke test for the new setting) |
| **S-20** | HEAD held; rewind lookup (commits API for the walk-back) errors with `BREW_COOLDOWN_FAIL_OPEN=1` set | `brew-cooldown install wget` | log warning `rewind lookup failed (...); BREW_COOLDOWN_FAIL_OPEN=1, letting current HEAD through`; exec `brew install wget` for the current HEAD; exit 0 — fail-open spans both the initial check and the rewind lookup |
| **S-20b** | same scenario as S-20 but `BREW_COOLDOWN_FAIL_OPEN` unset (default fail-closed) | `brew-cooldown install wget` | exit 2; stderr contains `fail-closed` and the lookup error reason; **no** brew exec; **no** raw fetch |
| **S-21** | rewind happens (same setup as S-14) | `brew-cooldown install wget` | stderr contains exactly the form `wget: HELD at HEAD; rewinding to <sha> (<N>d ago, <iso>)` with sha matching the picked N-stable commit, age in days as the integer floor of `(now − commit_date) / 86400`, and iso the committer date verbatim — the audit-trail line is stable so log scrapers and humans can rely on it |

## Pure-function unit-spec rows

| ID | Function | Input | Expected output |
|---|---|---|---|
| **U-01** | `validate_formula_name` | `wget` | exit 0 |
| **U-02** | `validate_formula_name` | `wget; rm` | exit 1 |
| **U-03** | `validate_formula_name` | empty string | exit 1 |
| **U-04** | `validate_formula_name` | string of length 101 | exit 1 |
| **U-05** | `validate_formula_name` | `Pillow` (uppercase allowed mid-name) — *but our regex allows lowercase start only; document that Homebrew names are lowercase by convention* | exit 1 — we are stricter than Homebrew on purpose |
| **U-06** | `mask_token` | `Bearer ghp_abc123def456` | output replaces token with `***REDACTED***` |
| **U-07** | `iso_to_epoch` | `2026-04-01T00:00:00Z` | matches `date -u -d @<epoch>` round-trip |
| **U-08** | `age_days` | (now-3d ISO) | `3` |
| **U-09** | `load_config` | line `BREW_COOLDOWN_DAYS=14` | sets `_cfg_BREW_COOLDOWN_DAYS=14` |
| **U-10** | `load_config` | line `EVIL=$(rm -rf /)` | rejected (not in allowlist), no var set |
| **U-11** | `repo_path_for` | `wget`, `formula` | `Formula/w/wget.rb` |
| **U-12** | `repo_path_for` | `font-fira-code`, `cask` | `Casks/font/font-fira-code.rb` |
| **U-13** | `repo_path_for` | `0xed`, `cask` | `Casks/0/0xed.rb` |
| **U-14** | `find_n_stable_commit` | commits=[(sha=h, t=now-3d), (sha=p, t=now-12d), (sha=q, t=now-30d)], days=7 | returns sha=`p` (gap to next-later h = 9d ≥ 7) |
| **U-15** | `find_n_stable_commit` | commits=[(R, now-4d), (M, now-7d), (L, now-27d)], days=7 (the malicious-then-reverted timeline) | returns sha=`L` — `R` not N-stable (HEAD, age 4 < 7), `M` not N-stable (gap to R = 3 < 7), `L` N-stable (gap to M = 20 ≥ 7) |
| **U-16** | `find_n_stable_commit` | 30 commits with every gap < 7d, days=7, max=30 | returns "not found" (non-zero exit / empty sentinel); caller surfaces S-16 verdict |
| **U-17** | `find_n_stable_commit` | single commit at now-10d (no later commits), days=7 | returns that single sha (HEAD case: `now − T ≥ N` satisfies N-stable) |
| **U-18** | `find_n_stable_commit` | single commit at now-3d (no later commits, fresh), days=7 | returns "not found" — preserves today's "hold" behavior when there's no history to rewind into |

## CI test boundary (important)

Real `brew install`, `brew upgrade`, and `brew reinstall` are **never** invoked in CI. Tests assert on the **argv** that *would* be passed to `brew` (via a shimmed `brew` function on PATH that just records its arguments). This is a deliberate boundary so CI cannot pwn itself with a malicious formula.

`brew outdated --json=v2` and `brew info --cask --json=v2` are also shimmed (they're read-only in real life, but mocking keeps tests deterministic and offline).

The only network call exercised is **GitHub's commits API**, and even that is shimmed via a `curl` function on PATH that returns fixture JSON.

## Manual / out-of-CI verification

`--dry-run` is the user's primary tool for spot-checking against real Homebrew + real GitHub:

```sh
brew-cooldown --dry-run install wget        # prints brew argv, exits 0
brew-cooldown --dry-run upgrade             # parses real brew outdated, prints survivor list
brew-cooldown --debug --dry-run install <pkg>   # prints redacted curl URL + parsed date
```
