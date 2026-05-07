# Architecture Decision Records

Each ADR captures one decision, the context that drove it, and the trade-offs we accepted. ADRs are append-only: if a decision changes, mark the old one `Status: Superseded by ADR-NNNN` and add a new one.

| # | Title | Status |
|---|---|---|
| [0001](0001-language-bash.md) | Language: Bash for v1 | Accepted |
| [0002](0002-data-source-github-commits.md) | Version-age data source: GitHub commits API | Accepted |
| [0003](0003-fail-closed-default.md) | Fail-closed by default on errors | Accepted |
| [0004](0004-version-heuristic-latest-commit.md) | Version heuristic: latest commit date for the formula file | Accepted |
| [0005](0005-wrapped-subcommand-scope.md) | Wrapped subcommands: install, upgrade, reinstall | Accepted |
| [0006](0006-no-brew-intercept.md) | We do not replace or shim `brew` | Accepted |
| [0007](0007-config-precedence.md) | Config precedence and config-file format | Accepted |

## Format

```markdown
# ADR-NNNN: Title

**Status:** Accepted | Superseded by ADR-XXXX | Deprecated

**Context:** the problem and constraints

**Decision:** what we chose

**Consequences:** what we accept (good and bad)

**Alternatives considered:** what we rejected and why
```
