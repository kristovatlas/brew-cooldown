# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- README "Why" section now cites prior art (pnpm 11 `minimumReleaseAge` default, Mini Shai-Hulud context, Endor Labs / Socket guidance) and links the three open Homebrew tracking issues (#21129, #21421, #22000)
- Initial v1: `brew-cooldown install|upgrade|reinstall` with default 7-day cooldown
- GitHub commits API as the version-release-date data source
- Fail-closed default; `BREW_COOLDOWN_FAIL_OPEN=1` to flip
- `--dry-run`, `--debug`, `--no-cooldown`, `--days`, `--cask` flags
- Cask support via `Homebrew/homebrew-cask`
- bats-core test suite covering all spec rows
- ADRs documenting language, data source, fail-closed, version heuristic, scope, no-shim, config precedence
- STRIDE-lite threat model
- Mermaid architecture diagrams (context + sequence)
- GitHub Actions CI: shellcheck, shfmt, bats, gitleaks
