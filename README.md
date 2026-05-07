# brew-cooldown

A defensive wrapper around Homebrew that refuses to install, upgrade, or reinstall a formula whose current version landed in `homebrew-core` (or `homebrew-cask`) less than `N` days ago. Default `N=7`.

## Why

Homebrew formulae are Ruby files. `brew install <pkg>` and `brew upgrade <pkg>` run arbitrary Ruby at install time — the same threat profile as an npm `postinstall` script. Homebrew is also widely used as a developer workstation package manager, which makes a compromised popular formula a high-yield target. If a maintainer account or formula PR is compromised and a malicious version lands in `homebrew-core` or `homebrew-cask`, anyone who runs `brew install`/`brew upgrade` in the next few hours or days executes the payload. By the time the security community catches and reverts it, the damage is done.

### Prior art

The JavaScript ecosystem has been adopting this exact pattern after a string of 2025–2026 supply-chain compromises (the [Mini Shai-Hulud](https://socket.dev/blog/pnpm-11-adds-new-supply-chain-protection-defaults) campaign hit npm, PyPI, and Packagist):

- **[pnpm 11](https://pnpm.io/blog/releases/11.0)** ships [`minimumReleaseAge`](https://pnpm.io/settings#minimumreleaseage) defaulting to **1440 minutes (1 day)** — newly published package versions aren't resolved until they're at least 24 hours old.
- pnpm's official [supply-chain security guide](https://pnpm.io/supply-chain-security) recommends using a longer minimum release age.
- Security tooling and guidance from Socket, Endor Labs, and others recommend the same pattern across the npm ecosystem.

Homebrew has **open issues requesting this exact feature** — none implemented as of writing:

- [Homebrew/brew#21129](https://github.com/Homebrew/brew/issues/21129) — *dependency cooldown to mitigate supply chain attacks* (Nov 2025)
- [Homebrew/brew#21421](https://github.com/Homebrew/brew/issues/21421) — *Minimum age during `brew install` and `brew upgrade`* (Jan 2026)
- [Homebrew/brew#22000](https://github.com/Homebrew/brew/issues/22000) — *Add optional cooldown window arg to `brew outdated`* (Apr 2026)

`brew-cooldown` is a small external wrapper that fills the gap until Homebrew ships first-class support. It introduces a **window of skepticism**: hold off on new versions for a few days while the broader community (and Homebrew maintainers) have a chance to detect and revert compromises.

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
