#!/usr/bin/env bash
# tests/coverage.sh — run the bats suite under kcov and report line coverage
# of bin/brew-cooldown and install.sh.
#
# Usage:
#   ./tests/coverage.sh                  run locally; print summary; HTML at coverage/
#   ./tests/coverage.sh --ci             additionally write to $GITHUB_STEP_SUMMARY
#   ./tests/coverage.sh --ci --threshold 80
#                                        exit non-zero if line coverage drops below 80%
#
# Requires: kcov, bats, jq, curl on PATH.
#   macOS:  brew install kcov bats-core jq
#   Ubuntu: sudo apt-get install -y kcov jq curl
#           (bats: see https://github.com/bats-core/bats-core)

set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
COV_DIR="${ROOT}/coverage"
CI_MODE=0
THRESHOLD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ci)        CI_MODE=1; shift ;;
        --threshold) THRESHOLD="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown arg: $1 (try --help)" >&2; exit 1 ;;
    esac
done

for tool in kcov bats jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: '$tool' is not installed. See header of $0 for install hints." >&2
        exit 1
    fi
done

rm -rf "$COV_DIR"
mkdir -p "$COV_DIR"

echo "Running kcov over bats suite..." >&2
# --include-pattern matches by substring against full file paths, so this
# captures bin/brew-cooldown and install.sh while ignoring everything else
# (bats internals, jq, curl).
kcov \
    --include-pattern=brew-cooldown,install.sh \
    --exclude-pattern=tests \
    "$COV_DIR" \
    bats -r "$ROOT/tests/" >/dev/null

# kcov writes a merged JSON at $COV_DIR/coverage.json (top-level summary)
# and per-binary subdirs. Pick whichever is present.
SUMMARY=""
for j in "$COV_DIR/coverage.json" "$COV_DIR"/*/coverage.json; do
    if [[ -f "$j" ]]; then SUMMARY="$j"; break; fi
done

if [[ -z "$SUMMARY" ]]; then
    echo "WARN: kcov produced no coverage.json. Check $COV_DIR/index.html manually." >&2
    PCT="?"
    COVERED="?"
    TOTAL="?"
else
    PCT=$(jq -r '.percent_covered // .covered // "?"' "$SUMMARY")
    COVERED=$(jq -r '.covered_lines // .covered // "?"' "$SUMMARY")
    TOTAL=$(jq -r '.total_lines // .total // "?"' "$SUMMARY")
fi

printf '\nLine coverage: %s%% (%s/%s lines)\nHTML report:  %s/index.html\n\n' \
    "$PCT" "$COVERED" "$TOTAL" "$COV_DIR" >&2

if [[ "$CI_MODE" -eq 1 && -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        echo "## Coverage"
        echo ""
        echo "| Metric | Value |"
        echo "|---|---|"
        echo "| Line coverage | **${PCT}%** |"
        echo "| Covered lines | ${COVERED} |"
        echo "| Total lines | ${TOTAL} |"
        echo ""
        echo "Full HTML report uploaded as the \`coverage-html\` artifact."
    } >> "$GITHUB_STEP_SUMMARY"
fi

if [[ -n "$THRESHOLD" ]]; then
    # Strip any non-numeric (e.g., "85.5" → 85)
    PCT_INT="${PCT%%.*}"
    if [[ "$PCT_INT" =~ ^[0-9]+$ ]] && (( PCT_INT < THRESHOLD )); then
        echo "ERROR: coverage ${PCT}% is below threshold ${THRESHOLD}%" >&2
        exit 1
    fi
fi
