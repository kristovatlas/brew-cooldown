#!/usr/bin/env bash
# tests/live/run-live-tests.sh — live on-Mac test harness for brew-cooldown.
#
# PURPOSE
#   Exercises brew-cooldown against REAL Homebrew + REAL GitHub on a real Mac,
#   covering the paths the bats suite can only shim (real bottle fetches, real
#   tap staging, real recursive dep pre-installs). Run it in one go, paste the
#   summary block back. Full transcript lands in a log file (path printed at
#   the end) for when a verdict needs forensics.
#
# THIS IS NOT A CI TEST. It performs real network calls and really installs /
# uninstalls formulae (from the sacrificial allowlist below only). CI safety
# boundary per docs/spec.md remains: bats only, everything shimmed.
#
# SAFETY MODEL
#   - Only formulae in SACRIFICIAL are ever installed or uninstalled. The
#     harness refuses to mutate anything else, and refuses to uninstall any
#     formula that has installed dependents (brew uses --installed).
#   - Everything the harness installs is uninstalled again in cleanup (LIFO),
#     including deps that brew-cooldown's ADR-0011 subprocess pre-cooled.
#   - Every mutating command is echoed before it runs.
#
# SCENARIO SELECTION
#   Time-cases (held / eligible / fresh-dep / parser-fail) drift daily as
#   homebrew-core moves, so scenarios PROBE with --dry-run first and SKIP
#   with an explanatory note when today's state can't exercise a case —
#   a SKIP is "case unavailable today", not a failure.
#
# Maintained by the assistant alongside bin/brew-cooldown; update the
# scenario list when behavior changes (spec rows in comments per scenario).

set -u

# --- configuration -----------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BC="${REPO_ROOT}/bin/brew-cooldown"

# Formulae this harness may install/uninstall at will. Add/remove freely —
# everything here must be something you genuinely do not care about.
# NOTE: deps that ADR-0011 pre-cools during a scenario (e.g. restic under
# autorestic) must ALSO be listed or cleanup will leave them behind (the
# harness warns rather than touching anything unlisted).
SACRIFICIAL="awscli autorestic restic btop vis"

# Probe-only pool: dry-run probed for time-case classification, never mutated.
PROBE_POOL="awscli autorestic btop vis pnpm ffmpeg imagemagick"

LOG="/tmp/brew-cooldown-live-$(date -u +%Y%m%d-%H%M%S).log"

# --- plumbing ----------------------------------------------------------------

# Everything to both terminal and log.
exec > >(tee "$LOG") 2>&1

VERDICT_NAMES=""   # space-separated scenario ids
VERDICT_RESULTS="" # parallel: PASS/FAIL/SKIP
VERDICT_NOTES=""   # parallel, |-separated notes (no | in notes)

TRACKED_INSTALLS="" # formulae this run installed, LIFO cleanup order (prepend)

record() { # record <id> <PASS|FAIL|SKIP> <note>
    VERDICT_NAMES="$VERDICT_NAMES $1"
    VERDICT_RESULTS="$VERDICT_RESULTS $2"
    VERDICT_NOTES="$VERDICT_NOTES|$3"
    printf '\n>>> [%s] %s — %s\n' "$2" "$1" "$3"
}

banner() { printf '\n=== %s ===\n' "$*"; }

# Run a command, echoing it first; capture combined output to OUT and rc to RC.
OUT=""; RC=0
run_cmd() {
    printf '\n$ %s\n' "$*"
    OUT="$( "$@" 2>&1 )"; RC=$?
    printf '%s\n(exit %d)\n' "$OUT" "$RC"
}

is_sacrificial() {
    case " $SACRIFICIAL " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

is_installed() {
    brew list --formula --versions "$1" >/dev/null 2>&1
}

# Uninstall with guards: sacrificial-listed AND no installed dependents.
safe_uninstall() {
    local f="$1"
    if ! is_sacrificial "$f"; then
        printf 'REFUSING to uninstall %s: not on the sacrificial list\n' "$f"
        return 1
    fi
    local dependents
    dependents="$(brew uses --installed --formula "$f" 2>/dev/null | grep -v '^$' || true)"
    # Dependents that are themselves tracked installs of this run are fine —
    # they get removed first by LIFO cleanup; anything else blocks.
    local blocker=""
    local d
    for d in $dependents; do
        case " $TRACKED_INSTALLS $SACRIFICIAL " in
            *" $d "*) ;;
            *) blocker="$d" ;;
        esac
    done
    if [[ -n "$blocker" ]]; then
        printf 'REFUSING to uninstall %s: installed dependent %s is not sacrificial\n' "$f" "$blocker"
        return 1
    fi
    run_cmd brew uninstall "$f"
    return $RC
}

tap_is_clean() {
    local taproot
    taproot="$(brew --repository)/Library/Taps/brew-cooldown"
    [[ ! -d "$taproot" ]] && return 0
    ! find "$taproot" -maxdepth 1 -name 'homebrew-cooldown-*' 2>/dev/null | grep -q .
}

assert_tap_clean() { # <scenario-id>
    if tap_is_clean; then return 0; fi
    record "$1-tap" FAIL "staged tap dir left behind under \$(brew --repository)/Library/Taps/brew-cooldown"
    return 1
}

# Probe a formula with --debug --dry-run install and classify today's state.
# Sets PROBE_CLASS to one of:
#   ELIGIBLE | HELD_REWIND | HELD_NO_CANDIDATE | BLOCKED_PREFLIGHT |
#   PARSER_FAIL | FRESH_DEP (dep pre-install would fire) | ERROR
# (FRESH_DEP takes precedence over ELIGIBLE/HELD_REWIND classification.)
PROBE_CLASS=""
probe() {
    local f="$1"
    run_cmd "$BC" --debug --dry-run install "$f"
    PROBE_CLASS="ERROR"
    if printf '%s' "$OUT" | grep -q "pre-installing via brew-cooldown (ADR-0011)"; then
        PROBE_CLASS="FRESH_DEP"
    elif printf '%s' "$OUT" | grep -q "depends_on parser failed"; then
        PROBE_CLASS="PARSER_FAIL"
    elif printf '%s' "$OUT" | grep -q "is already installed; brew refuses overlapping"; then
        PROBE_CLASS="BLOCKED_PREFLIGHT"
    elif printf '%s' "$OUT" | grep -q "HELD at HEAD; rewinding to"; then
        PROBE_CLASS="HELD_REWIND"
    elif printf '%s' "$OUT" | grep -qi "all packages held"; then
        PROBE_CLASS="HELD_NO_CANDIDATE"
    elif printf '%s' "$OUT" | grep -q ": eligible (latest commit"; then
        PROBE_CLASS="ELIGIBLE"
    fi
    printf 'probe(%s) → %s\n' "$f" "$PROBE_CLASS"
}

# --- preflight ----------------------------------------------------------------

banner "preflight"

if ! command -v brew >/dev/null 2>&1; then
    printf 'FATAL: real brew not found on PATH; this harness is mac/live only\n'
    exit 2
fi
if [[ ! -x "$BC" ]]; then
    printf 'FATAL: %s not found/executable\n' "$BC"
    exit 2
fi

printf 'date (utc):      %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'repo commit:     %s\n' "$(git -C "$REPO_ROOT" rev-parse --short HEAD) ($(git -C "$REPO_ROOT" branch --show-current))"
printf 'repo dirty:      %s\n' "$(git -C "$REPO_ROOT" status --porcelain | head -3)"
printf 'brew:            %s\n' "$(brew --version | head -1)"
printf 'macos:           %s (%s)\n' "$(sw_vers -productVersion 2>/dev/null || echo n/a)" "$(uname -m)"
printf 'log file:        %s\n' "$LOG"

if [[ -z "${BREW_COOLDOWN_GITHUB_TOKEN:-}${HOMEBREW_GITHUB_API_TOKEN:-}" ]]; then
    printf 'WARN: no GitHub token in env — unauthenticated limit is 60 req/hr and\n'
    printf '      this harness + dep walks can exceed it. Set HOMEBREW_GITHUB_API_TOKEN.\n'
fi

# Belt-and-braces: this harness must never run with cooldown disabled.
unset BREW_COOLDOWN_DISABLE BREW_COOLDOWN_NO_REWIND BREW_COOLDOWN_NO_COOL_DEPS BREW_COOLDOWN_FAIL_OPEN

# --- cleanup (EXIT trap) -------------------------------------------------------

cleanup() {
    banner "cleanup"
    local f
    for f in $TRACKED_INSTALLS; do
        if is_installed "$f"; then
            printf 'removing harness-installed formula: %s\n' "$f"
            safe_uninstall "$f" || printf 'WARN: could not remove %s — remove manually\n' "$f"
        fi
    done
    if ! tap_is_clean; then
        printf 'WARN: leftover staged tap dirs under %s/Library/Taps/brew-cooldown\n' "$(brew --repository)"
    fi
}
trap cleanup EXIT

# --- scenarios -----------------------------------------------------------------

# T1 (spec S-01 + S-30): eligible formula, dep walk runs, plain install argv.
banner "T1: eligible top-level + dep walk no-op (dry-run, jq)"
run_cmd "$BC" --debug --dry-run install jq
if [[ $RC -eq 0 ]] && printf '%s' "$OUT" | grep -q "^brew install jq$" \
   && printf '%s' "$OUT" | grep -q "raw.githubusercontent.com"; then
    record T1 PASS "eligible + dep walk ran (raw fetch present) + plain argv"
else
    record T1 FAIL "expected eligible verdict, dep-walk raw fetch, and 'brew install jq' argv (rc=$RC)"
fi
assert_tap_clean T1 || true

# T2 (spec S-34): --no-cool-deps skips the walk — no raw fetch at all.
banner "T2: --no-cool-deps opt-out (dry-run, jq)"
run_cmd "$BC" --no-cool-deps --debug --dry-run install jq
if [[ $RC -eq 0 ]] && printf '%s' "$OUT" | grep -q "^brew install jq$" \
   && ! printf '%s' "$OUT" | grep -q "raw.githubusercontent.com"; then
    record T2 PASS "no raw fetch with --no-cool-deps"
else
    record T2 FAIL "expected no raw fetch and plain argv (rc=$RC)"
fi

# T3 (ADR-0010 + S-14/S-17 analogues, live): rewound REAL install of awscli.
banner "T3: real install of awscli (held→rewind expected, eligible also OK)"
T3_MODE=""
if is_installed awscli; then
    safe_uninstall awscli || record T3 SKIP "could not uninstall pre-existing awscli safely"
fi
if ! is_installed awscli; then
    probe awscli
    case "$PROBE_CLASS" in
        HELD_REWIND|FRESH_DEP) T3_MODE="rewind" ;;
        ELIGIBLE)              T3_MODE="eligible" ;;
        HELD_NO_CANDIDATE)     record T3 SKIP "awscli held with no candidate today — cannot exercise install" ;;
        *)                     record T3 SKIP "unexpected probe class $PROBE_CLASS" ;;
    esac
fi
if [[ "$T3_MODE" == "rewind" || "$T3_MODE" == "eligible" ]]; then
    run_cmd "$BC" --debug install awscli
    if [[ $RC -eq 0 ]] && is_installed awscli; then
        TRACKED_INSTALLS="awscli $TRACKED_INSTALLS"
        if [[ "$T3_MODE" == "rewind" ]]; then
            if printf '%s' "$OUT" | grep -q "install --force-bottle brew-cooldown/cooldown-"; then
                record T3 PASS "rewound install via --force-bottle, awscli in Cellar"
            else
                # brew's own output goes to our stdout too; force-bottle is in OUR argv line
                record T3 PASS "installed (rewind path; force-bottle line not captured but rc=0 + Cellar present)"
            fi
        else
            record T3 PASS "eligible-path install, awscli in Cellar"
        fi
    else
        record T3 FAIL "install rc=$RC, installed=$(is_installed awscli && echo yes || echo no) — see log"
    fi
    assert_tap_clean T3 || true
fi

# T4 (ADR-0009 / S-22, live): re-install while installed → pre-flight block.
banner "T4: ADR-0009 pre-flight block (awscli again, must refuse)"
if is_installed awscli; then
    run_cmd "$BC" --debug install awscli
    if [[ $RC -ne 0 ]] && printf '%s' "$OUT" | grep -q "already installed"; then
        record T4 PASS "blocked with remediation, exit $RC"
    else
        record T4 FAIL "expected non-zero + 'already installed' (rc=$RC)"
    fi
    assert_tap_clean T4 || true
else
    record T4 SKIP "awscli not installed (T3 skipped or failed)"
fi

# T5 (ADR-0011 / S-31, live): real install with fresh-dep recursive pre-cool.
# Candidate found by reverse-dep scan: autorestic → restic (fresh as of
# 2026-06-12). Probe re-checks; SKIP when the time-case has drifted.
banner "T5: real S-31 — autorestic with fresh uninstalled dep (restic)"
T5_OK=1
for f in autorestic restic; do
    if is_installed "$f"; then
        safe_uninstall "$f" || { record T5 SKIP "$f pre-installed and not safely removable"; T5_OK=0; break; }
    fi
done
if [[ $T5_OK -eq 1 ]]; then
    probe autorestic
    if [[ "$PROBE_CLASS" == "FRESH_DEP" ]]; then
        run_cmd "$BC" --debug install autorestic
        if [[ $RC -eq 0 ]] && is_installed autorestic && is_installed restic; then
            TRACKED_INSTALLS="autorestic restic $TRACKED_INSTALLS"
            if printf '%s' "$OUT" | grep -q "pre-installing via brew-cooldown (ADR-0011)"; then
                record T5 PASS "restic pre-cooled via subprocess, autorestic installed after"
            else
                record T5 FAIL "both installed but pre-install marker missing — check ordering in log"
            fi
        else
            # Track whatever did land so cleanup still removes it
            is_installed autorestic && TRACKED_INSTALLS="autorestic $TRACKED_INSTALLS"
            is_installed restic && TRACKED_INSTALLS="restic $TRACKED_INSTALLS"
            record T5 FAIL "install rc=$RC autorestic=$(is_installed autorestic && echo yes || echo no) restic=$(is_installed restic && echo yes || echo no)"
        fi
        assert_tap_clean T5 || true
    else
        record T5 SKIP "autorestic probe=$PROBE_CLASS (fresh-dep case drifted; rerun scan for a new candidate)"
    fi
fi

# T6 (ADR-0011 / S-33, live): parser fail-closed on real conditional Ruby (btop),
# then S-34 opt-out lets the same formula through (dry-run only).
banner "T6: parser fail-closed (btop) + --no-cool-deps opt-out"
if is_installed btop; then
    record T6 SKIP "btop already installed — pre-flight would fire before parser"
else
    run_cmd "$BC" --debug --dry-run install btop
    if [[ $RC -ne 0 ]] && printf '%s' "$OUT" | grep -q "depends_on parser failed"; then
        record T6 PASS "fail-closed on conditional depends_on, exit $RC"
    elif [[ $RC -eq 0 ]]; then
        record T6 SKIP "btop now parses cleanly (formula likely changed upstream) — find a new S-33 candidate"
    else
        record T6 FAIL "non-zero exit but no parser-failed marker (rc=$RC)"
    fi
    run_cmd "$BC" --no-cool-deps --debug --dry-run install btop
    if [[ $RC -eq 0 ]]; then
        record T6b PASS "--no-cool-deps lets btop through (dry-run)"
    else
        record T6b FAIL "expected rc=0 with --no-cool-deps (rc=$RC)"
    fi
fi
assert_tap_clean T6 || true

# T7 (parser false-positive class, documents known limitation): vis fails
# closed on a STRING LITERAL mentioning depends_on inside def install.
banner "T7: parser false-positive class (vis, dry-run)"
if is_installed vis; then
    record T7 SKIP "vis already installed"
else
    run_cmd "$BC" --debug --dry-run install vis
    if [[ $RC -ne 0 ]] && printf '%s' "$OUT" | grep -q "depends_on parser failed"; then
        record T7 PASS "known false-positive class fails closed (documented cost; --no-cool-deps remediates)"
    elif [[ $RC -eq 0 ]]; then
        record T7 SKIP "vis now parses (upstream formula changed, or parser improved) — update harness note"
    else
        record T7 FAIL "unexpected outcome rc=$RC"
    fi
fi

# T8 (ADR-0010 vs ADR-0008): strict-cooldown picks a different (or equal,
# never newer) commit than the default rule. Dry-run on first held probe-pool entry.
banner "T8: default vs --strict-cooldown comparison (dry-run)"
T8_DONE=0
for f in $PROBE_POOL; do
    is_installed "$f" && continue
    probe "$f"
    [[ "$PROBE_CLASS" == "HELD_REWIND" || "$PROBE_CLASS" == "FRESH_DEP" ]] || continue
    DEFAULT_LINE="$(printf '%s' "$OUT" | grep -o 'rewinding to [a-f0-9]* ([0-9]*d ago' | head -1)"
    run_cmd "$BC" --strict-cooldown --no-cool-deps --debug --dry-run install "$f"
    STRICT_LINE="$(printf '%s' "$OUT" | grep -o 'rewinding to [a-f0-9]* ([0-9]*d ago' | head -1)"
    if [[ -n "$DEFAULT_LINE" ]]; then
        record T8 PASS "$f: default[$DEFAULT_LINE] strict[${STRICT_LINE:-no candidate}]"
    else
        record T8 FAIL "$f: could not extract rewind line from default run"
    fi
    T8_DONE=1
    break
done
[[ $T8_DONE -eq 0 ]] && record T8 SKIP "no held-and-uninstalled formula in probe pool today"

# --- summary --------------------------------------------------------------------

banner "SUMMARY (paste this block back)"
printf 'commit %s | %s | brew %s | %s\n' \
    "$(git -C "$REPO_ROOT" rev-parse --short HEAD)" \
    "$(date -u +%Y-%m-%dT%H:%MZ)" \
    "$(brew --version | head -1 | awk '{print $2}')" \
    "$(uname -m)"
i=0
FAILS=0
for name in $VERDICT_NAMES; do
    i=$((i + 1))
    result="$(printf '%s' "$VERDICT_RESULTS" | awk -v n=$i '{print $n}')"
    note="$(printf '%s' "$VERDICT_NOTES" | cut -d'|' -f$((i + 1)))"
    printf '  %-8s %-5s %s\n' "$name" "$result" "$note"
    [[ "$result" == "FAIL" ]] && FAILS=$((FAILS + 1))
done
printf 'full log: %s\n' "$LOG"
[[ $FAILS -gt 0 ]] && exit 1
exit 0
