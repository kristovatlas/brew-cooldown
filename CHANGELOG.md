# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `tests/coverage.sh` — kcov-based line coverage script with `--ci` and `--threshold` flags
- New CI job `coverage (kcov)` (pinned to `ubuntu-22.04` since 24.04/noble dropped kcov from apt): runs the bats suite under kcov, posts coverage % to the workflow step summary, uploads HTML report as `coverage-html` artifact
- README and CONTRIBUTING.md document how to view coverage locally and in CI
- v1 baseline: 86% line coverage (238 / 275 lines)
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
