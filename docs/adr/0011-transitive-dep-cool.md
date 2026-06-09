# ADR-0011: Transitive dependency cooldown (Tier 1)

**Status:** Accepted

## Context

[Threat-model.md non-mitigation #11](../threat-model.md) documents a real defense gap: when a user runs `brew-cooldown install <name>`, brew's own dependency resolver pulls in transitive deps from `homebrew-core`'s current HEAD with no cooldown intervention. The awscli install used to demonstrate ADR-0010 made this concrete — brew pulled in `openssl@3`, `sqlite`, `xz`, and `python@3.14`, two of which (`sqlite`, `python@3.14`) were themselves fresh enough in `homebrew-core` that they'd have been held had they been the user-invoked install.

The user formalized the framing for closing this gap during the design discussion:

> *"For obstacle 3, I don't think we should fiddle with formula that have already been installed. We're not building an auditing tool, but a forward-looking firewalling tool."*

And:

> *"if both responses are bad, can we just not take action and warn the user appropriately instead?"* (re: trying to "fix" already-installed-but-fresh deps by uninstalling or rewriting formulae)

These two framings — **forward-looking firewall, not retroactive auditor** — collapse the design space substantially. The earlier internal design discussion explored a "Tier 2" approach (full pnpm-style transitive cool: rewrite every `depends_on` line in staged formulae to tap-qualify cool versions, multi-tap orchestration, ABI compatibility detection) but rejected it for v1 — it requires Ruby DSL rewriting and cascading uninstalls, both of which fight brew rather than ride alongside it.

Tier 1 (this ADR) implements the firewall: for any new code entering the system as part of a wrapped install, apply the cooldown. For code already on disk, defer to whatever the user installed it with.

## Decision

**brew-cooldown gates transitive dependencies of any wrapped install command by default.** For each dep brew would freshly install (or upgrade to a new version) as part of the user-invoked top-level install, brew-cooldown pre-installs the dep via its own single-formula cooldown logic first, in topological order. Already-installed deps that brew would use as-is are not touched.

### Default-on, opt-out

- **Default-on.** Consistent with ADR-0008 / 0009 / 0010 — strongest default protection. The cooldown's promise extends to the full set of new code entering the system.
- **Opt-out via `--no-cool-deps` / `BREW_COOLDOWN_NO_COOL_DEPS=1`.** For users who need the pre-ADR-0011 behavior (e.g., installing a formula whose dep tree contains a `depends_on` line our parser cannot safely interpret), or who prefer the previous strict semantics where only the top-level was gated.

### Per-dep classification (the four cases)

After parsing the rewound top-level formula's `depends_on` lines and walking the dep tree, each transitive dep falls into exactly one of:

| dep state | action | rationale |
|---|---|---|
| **Already installed at version V; brew will use it as-is** | No action. | Firewall, not auditor: pre-existing installs of any age are out of scope. |
| **Already installed at version V; brew will upgrade to version W for this command** | Treat as a new install of W → pre-install W via brew-cooldown first. | The upgrade introduces new code; the firewall gates it. |
| **Not installed; current homebrew-core HEAD is ≥N days old (eligible)** | No action; brew installs the current version normally. | Would have been eligible under the cooldown anyway. |
| **Not installed; current homebrew-core HEAD is <N days old (fresh)** | Pre-install the dep via brew-cooldown (the dep's own cooldown decision applies — rewind, hold, etc.). | The firewall's standard cooldown promise on new code. |

Compatibility upgrades (the second row) are detected by inspecting brew's resolution plan — e.g., `brew install --dry-run` or equivalent — before invoking the actual install.

### Parsing `depends_on`: fail-closed on ambiguity

The parser handles the standard BrewTestBot-shaped patterns:

- `depends_on "name"` → runtime dep
- `depends_on "name" => :build|:test|:optional` → skip (not installed for bottle installs / not user-requested)
- `depends_on "name" => :recommended` → treat as runtime
- `depends_on macos:`/`arch:`/`xcode:` → platform/toolchain requirement, not a formula dep
- `uses_from_macos "name"` → real dep on Linux; no-op on macOS
- `on_macos { ... }`, `on_linux { ... }`, `on_arm { ... }`, `on_intel { ... }` → context-aware (parser knows which to recurse into based on the user's platform)
- `bottle do { ... }`, `head do { ... }`, `service do { ... }`, `livecheck do { ... }`, `patch do { ... }`, `resource do { ... }`, `test do { ... }`, `stable do { ... }` → skipped (not dep declarations)
- Inline comments after `depends_on "name"` (`depends_on "swig" => :build # for lldb`) → stripped before parsing

For anything else that mentions `depends_on` but doesn't match a recognized form — most commonly conditional Ruby like `depends_on "llvm" => :build if DevelopmentTools.clang_build_version <= 1699` — the parser refuses with a specific line citation and the install is held. **Fail-closed**: better to refuse than to silently miss a transitive dep we should have cooled.

User remediation when this happens:
1. Inspect the cited line, decide whether the dep matters for cooldown purposes.
2. If not (e.g., a `:build` dep that wouldn't be installed for the bottle), `--no-cool-deps` for this specific install.

Empirically (from the prototype run during the design discussion), ~94% of representative formulae parse cleanly with the inline-comment-strip; the failures are limited to a small set of formulae with conditional Ruby in their dep declarations. Most users will never hit a parse failure.

### Topological sort + per-dep pre-install

When ≥1 dep needs pre-installing (rows 2 and 4 above), brew-cooldown:

1. Walks the dep tree recursively from the staged top-level formula's content. Bounded depth (default 10) prevents pathological recursion.
2. Topologically sorts the deps to be pre-installed (dependencies-of-dependencies first).
3. For each dep in order, invokes the same single-formula `run_one_command install` logic with the dep name. This recursively applies all of brew-cooldown's protections (cooldown check, ADR-0010 rewind picker, ADR-0009 pre-flight installed check, staging tap, `--force-bottle`).
4. Each pre-install is a separate brew invocation; failures fail-stop (any single dep failing aborts the chain, since we'd otherwise leave the system partially-cooled).
5. After all pre-installs settle, invokes the original top-level install.

### Why not Tier 2 in v1

Tier 2 — full pnpm-style "the entire dep graph satisfies cooldown" — would require:
- Rewriting `depends_on` lines in staged formulae to tap-qualify cool dep versions (Ruby DSL parsing + writing)
- Multi-tap orchestration so brew installs each dep from the cool tap (not from `homebrew-core` HEAD)
- ABI compatibility analysis between rewound top-level and pre-installed cool dep versions
- Cascading uninstalls for installed deps that the user would need to replace (which transitively breaks other formulae's dep satisfactions)

Most of those would require us to deeply intercept brew's resolver in ways that ADR-0006 explicitly rejects, or build a parallel resolver. The user's "firewall not auditor" framing makes most of this unnecessary: we don't care about retroactively cooling already-installed deps, so we never need to replace them or rewrite formulae to reference our tap.

Tier 2 is documented as a future possible extension in the "Alternatives considered" section below. If a future use case demands point-in-time guarantees on the entire dep graph (e.g., reproducible builds, formal audit requirements), this ADR can be revisited.

## Consequences

**Accepted positives:**

- The cooldown's promise extends to all new code entering the system, not just the user-invoked top-level. The dominant gap from non-mitigation #11 is materially closed for forward-going installs.
- No new external trust surface — uses the same GitHub commits API + raw content fetch that ADR-0008/0010 already rely on.
- Existing per-dep behavior (ADR-0009 pre-flight, ADR-0010 picker, `--force-bottle` enforcement) applies recursively to pre-installed deps for free — each pre-install is just another `run_one_command install` invocation.
- Composes with `--strict-cooldown`: opt-in N-stable also applies to deps when set.
- Fail-closed semantics on parser failure preserve the project's security-first defaults.

**Accepted negatives:**

- **Additional API calls per install.** For each transitive dep, at least one commits-API call to check freshness; for fresh deps, the full ADR-0010 walk-back. For an awscli-shaped install with ~13 transitive runtime deps, this is ~13-50 additional calls. Tokenized rate limits make this fine (5000/hr); unauthenticated may rate-limit faster on heavy multi-formula workflows. Token mode becomes even more strongly recommended.
- **Slower top-level installs when ≥1 dep needs pre-installing.** Each pre-installed dep is its own brew invocation with its own tap staging. For a fresh-deps-heavy install, this can multiply wall-clock time significantly.
- **Parser-failure refusals on a small set of formulae** (currently ~6% of representative sample; node-shaped formulae with conditional Ruby in dep declarations are the typical case). User must `--no-cool-deps` for those.
- **Brew compatibility-upgrade detection** depends on `brew install --dry-run` output format. If brew changes that format, our parser must adapt. Fail-closed if we can't parse the plan.
- **Forward-looking only** (by design): pre-existing installs are grandfathered. Users who adopted brew-cooldown after installing many fresh formulae have those installs outside the firewall's scope — same as before this ADR.

## Alternatives considered

- **Tier 2 (pnpm-style full graph cool)** — rejected for v1 as detailed in the Decision section. Implementing it well would require multi-tap orchestration, Ruby DSL rewriting, ABI compatibility analysis, and cascading uninstall handling — none of which fit the project's narrow-scope philosophy or [ADR-0006](0006-no-brew-intercept.md)'s no-brew-intercept stance. Documented here as a future possible extension if a use case explicitly demands graph-level cooldown guarantees.
- **Opt-in via `--with-deps` flag, default off** — considered, rejected. Inconsistent with ADR-0008/0009/0010's default-on pattern; would hide the feature from users who'd benefit. The downside (refused installs on formulae with unparseable depends_on) is bounded (~6% of formulae) and the opt-out (`--no-cool-deps`) is one flag away.
- **Default-on for installs but opt-in for upgrades** — considered, rejected as too clever. Either the firewall applies to all wrapped installs or it doesn't.
- **Rewriting `depends_on` lines in staged formulae to tap-qualify cool versions** (a partial step toward Tier 2 without full multi-tap orchestration) — rejected: invasive Ruby DSL editing inside our staged formulae expands attack surface without delivering the full Tier 2 promise. Either commit to Tier 2 or stay in Tier 1.
- **Warn-only mode** that reports which deps would be cooled but doesn't pre-install them — considered, rejected. Informational without action doesn't materially improve user safety; the manual workflow already documented in non-mitigation #11 covers that case if users want it.
- **Use `brew deps --formula <name>` to enumerate deps instead of parsing the .rb file** — considered, rejected for Tier 1's case. The user-invoked install is of a *rewound* version; brew's CLI reports the *current* version's deps. We need to read the rewound formula's content, which means parsing it ourselves.
- **Recursive depth unbounded** — rejected; pathological inputs could lock the tool. Default depth 10 covers all real-world dep trees observed in homebrew-core.

## Forward references

- **Compatibility-upgrade detection (deferred from v1).** Detecting when brew would transparently upgrade an installed dep as part of the top-level install — by parsing `brew install --dry-run` output — was specified in S-32 but is deferred. Currently if brew upgrades an installed dep mid-install, that upgrade bypasses the cooldown. User remediation: `brew-cooldown install <dep>` explicitly before the top-level when the user suspects an upgrade will happen.
- A future iteration could add a `--cool-deps-depth=N` flag to tune the recursion depth, or a `--cool-deps-only=<list>` for users who want to selectively gate specific deps.
- The Tier 2 path (full graph cool with pnpm-style semantics) is documented in this ADR's "Alternatives considered" as a future possible extension if a use case justifies the scope expansion.
- Issue [#5](https://github.com/kristovatlas/brew-cooldown/issues/5) ("informative-refusal — show smaller-N rewind alternatives") still applies to each per-dep cooldown decision under this rule.
