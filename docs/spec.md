# brew-cooldown — behavior spec

This is the source of truth for what `brew-cooldown` does. Every row is paired with a bats test under `tests/integration/` (or `tests/unit/` for pure-function rows). If a row fails its test in CI, the build is red. If you change behavior, **update this table first**, then the tests, then the code.

## Wrapped subcommands

`brew-cooldown` only wraps three brew subcommands. Anything else is rejected with exit 1 and a usage message.

| Wrapped | Pass-through? | Why |
|---|---|---|
| `install <pkg>` | After cooldown OK | Same supply-chain risk as upgrade |
| `upgrade <pkg>` / `upgrade` | After cooldown OK (no-args = partial upgrade) | The motivating threat |
| `reinstall <pkg>` | After cooldown OK | Reinstalls re-pull the latest formula |
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
