# Contributing to brew-cooldown

## Branch model

- `main` — release / latest. Protected. PRs only, human review required.
- `dev` — work-in-progress. Claude and contributors push here freely.
- Feature branches off `dev` are encouraged for larger work.

## Spec-driven development

Behavior is specified in [`docs/spec.md`](docs/spec.md) as a Given/When/Then table. Every spec row should have a corresponding bats test. **If you change behavior, update the spec first, then the tests, then the code.** If you discover a deviation between code and spec on a branch, flag it explicitly in the PR description and reconcile (usually by updating the doc to match the new intentional behavior, or fixing the code to match the spec).

## Docs must track deviations

ADRs in [`docs/adr/`](docs/adr/) record design decisions. If a PR changes a decision, amend the ADR (Status: Superseded) and add a new one. Don't silently drift.

The threat model and architecture diagrams must stay in sync with the implementation. If your change affects what `brew-cooldown` protects against (or doesn't), update [`docs/threat-model.md`](docs/threat-model.md). If it affects the data flow or external dependencies, update [`docs/architecture.md`](docs/architecture.md) and the `.mmd` source.

## Local development

```sh
# install dev deps (linux):
sudo apt-get install -y shellcheck bats jq kcov
# (shfmt: download from https://github.com/mvdan/sh/releases)

# install dev deps (macOS):
brew install shellcheck shfmt bats-core jq kcov

# run lint + tests:
shellcheck bin/brew-cooldown install.sh tests/**/*.bash 2>/dev/null
shfmt -d -i 4 -ci bin/brew-cooldown install.sh
bats -r tests/
```

CI runs the same set on every PR.

## Test coverage

Line coverage is measured with [`kcov`](https://github.com/SimonKagstrom/kcov) over the bats suite. Run it locally:

```sh
./tests/coverage.sh
# → ./coverage/index.html
```

CI runs the same script with `--ci`, prints a coverage summary to the workflow step summary on every PR, and uploads the full HTML report as the `coverage-html` artifact.

To enforce a coverage floor in CI (e.g., for protected branches):

```sh
./tests/coverage.sh --ci --threshold 80   # exits non-zero if coverage < 80%
```

Note: real `brew install/upgrade/reinstall` is never invoked, even under coverage. If a code path can't be exercised without real brew, document that on the spec row and write the closest meaningful test (typically asserting the brew argv that *would* be invoked).

## Pull requests

- One PR per concern; keep diffs small.
- Use the PR template; fill in the security and docs checklists.
- All CI must be green.
- One human review approval required to merge to `main`.
