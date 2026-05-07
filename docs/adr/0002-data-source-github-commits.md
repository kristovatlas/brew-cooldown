# ADR-0002: Version-age data source — GitHub commits API

**Status:** Accepted

## Context

The whole tool hinges on one question: *when did the current version of formula X land in `homebrew-core`?* We surveyed the available data sources during planning:

- **`formulae.brew.sh/api/formula/{name}.json`** — Homebrew's official JSON API. Returns full formula metadata but **no version release timestamps**, only a `generated_date` for when the JSON was generated. Same gap on the cask API. Confirmed by inspecting `wget` and `git` JSON.
- **Local `brew log <formula>`** — works only if homebrew-core is locally cloned with full git history. Modern Homebrew defaults to `HOMEBREW_INSTALL_FROM_API=1` and may not have a local checkout at all.
- **`brew info --json=v2`** — same metadata as `formulae.brew.sh`; no timestamps.
- **GitHub commits API** — `GET /repos/Homebrew/homebrew-core/commits?path=Formula/w/wget.rb` returns commit history with ISO 8601 `commit.committer.date`. Public, anonymous-accessible. Rate-limited at 60/hr unauthenticated, 5000/hr with `HOMEBREW_GITHUB_API_TOKEN`. Same pattern works for `Homebrew/homebrew-cask` at `Casks/{first-char}/{name}.rb` (with a special case for `Casks/font/`).

## Decision

Use the GitHub commits API on `Homebrew/homebrew-core` (and `Homebrew/homebrew-cask` for casks) as the single data source for version-release-date.

Specifically:

```sh
GET https://api.github.com/repos/Homebrew/homebrew-core/commits?path=Formula/w/wget.rb&per_page=1
```

Parse `.[0].commit.committer.date`.

## Consequences

**Accepted positives:**

- Authoritative — every formula change is a commit; commits are immutable history.
- Works under `HOMEBREW_INSTALL_FROM_API` (no local clone required).
- One request per formula, light JSON.
- Free, anonymous-friendly, scales to 5000/hr with a free GitHub token.

**Accepted negatives:**

- Adds a dependency on github.com being up. Mitigated by fail-closed default: a network failure refuses, never silently passes through.
- Rate limit (60/hr unauthenticated) can bite power users. We surface a distinct error and recommend `BREW_COOLDOWN_GITHUB_TOKEN`.
- Trusts GitHub's HTTPS — see threat model non-mitigation #2.

## Alternatives considered

- **Mirror via formulae.brew.sh** — they don't publish timestamps; would require a PR upstream. Out of scope.
- **Self-host a metadata service** — adds infrastructure and a target for compromise. Defeats the point.
- **Walk local `homebrew-core` git history** — fails under `HOMEBREW_INSTALL_FROM_API`; rejected.
- **Use bottle build timestamps from formulae.brew.sh** — the `bottle` block has a `rebuild` integer but no timestamps; doesn't answer our question.

If GitHub becomes unsuitable in the future (e.g., aggressive rate limiting, deprecation), we'd need a replacement source. The ADR will be superseded when that happens.
