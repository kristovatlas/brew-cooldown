# brew-cooldown

A defensive wrapper around Homebrew that refuses to install, upgrade, or reinstall a formula whose current version landed in `homebrew-core` (or `homebrew-cask`) less than `N` days ago. Default `N=7`.

## Why

If a maintainer account or formula PR is compromised and a malicious version lands in `homebrew-core`, anyone who runs `brew upgrade <pkg>` in the next few hours or days gets the payload. By the time the security community catches and reverts the formula, you've already executed it. `brew-cooldown` introduces a **window of skepticism**: hold off on new versions for a few days while the broader community (and Homebrew maintainers) have a chance to detect and revert compromises.

This is **defense-in-depth**, not a primary control. Read [`docs/threat-model.md`](docs/threat-model.md) for what we mitigate and what we don't.

## Install

```sh
git clone https://github.com/<your-fork>/brew-cooldown.git
cd brew-cooldown
./install.sh
```

This symlinks `bin/brew-cooldown` into `/usr/local/bin` (or `~/.local/bin` if the former isn't writable). Re-run anytime to refresh. Requires `curl` and `jq` on `PATH`.

`brew-cooldown` is a **separate command**, not a replacement for `brew`. Keep using `brew` for everything else; reach for `brew-cooldown` when you want the cooldown check.

## Usage

```sh
brew-cooldown install <formula>           # install with cooldown check
brew-cooldown upgrade <formula>           # upgrade one
brew-cooldown upgrade                     # upgrade all eligible, hold the rest
brew-cooldown reinstall <formula>         # reinstall with cooldown check
brew-cooldown install --cask <name>       # cask form (same threat, different repo)
brew-cooldown --dry-run upgrade <name>    # show the brew command, don't run it
brew-cooldown --no-cooldown install <name>  # bypass (logs loudly to stderr)
```

Anything else (`search`, `info`, `update`, etc.) returns "unsupported subcommand" — by design. Use `brew` directly for those.

## Configuration

Precedence (high → low): CLI flag → env var → config file → default.

| Setting | Env var | CLI flag | Default |
|---|---|---|---|
| Cooldown days | `BREW_COOLDOWN_DAYS` | `--days N` | `7` |
| GitHub token | `BREW_COOLDOWN_GITHUB_TOKEN` (or `HOMEBREW_GITHUB_API_TOKEN`) | — | (none, 60 req/hr) |
| Fail open on errors | `BREW_COOLDOWN_FAIL_OPEN=1` | — | `0` (fail closed) |
| Disable check | `BREW_COOLDOWN_DISABLE=1` | `--no-cooldown` | `0` |

Config file: `${XDG_CONFIG_HOME:-$HOME/.config}/brew-cooldown/config`, format `KEY=value` per line. Allowlist parsed; **not** sourced as shell.

## Docs

- [`docs/spec.md`](docs/spec.md) — objective behavior spec
- [`docs/threat-model.md`](docs/threat-model.md) — what we protect against, what we don't
- [`docs/architecture.md`](docs/architecture.md) — how it works
- [`docs/adr/`](docs/adr/) — design decisions

## License

MIT. See [`LICENSE`](LICENSE).
