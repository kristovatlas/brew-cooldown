#!/usr/bin/env bats
# Spec rows S-14 through S-19 — N-stable rewind path (ADR-0008).
#
# The rewind path:
#   1. check_cooldown of HEAD returns "held"
#   2. try_rewind walks the commits API for an N-stable predecessor
#   3. fetch_formula_content gets the historical .rb body at that SHA
#   4. stage_formula writes it into a per-invocation tap under
#      ${BC_BREW_REPO}/Library/Taps/brew-cooldown/homebrew-cooldown-XXXXXX/
#   5. exec brew install --force-bottle brew-cooldown/cooldown-XXXXXX/<name>
#   6. on EXIT, the tap dir is rm -rf'd.

load ../test_helper

setup()    { bc_setup; }
teardown() { bc_teardown; }

@test "S-14: rewind happy path — HEAD held, N-stable predecessor exists, brew called with --force-bottle" {
    # HEAD=h at 3d ago (held), p at 12d ago (N-stable: gap to h = 9 ≥ 7), q at 30d ago
    bc_curl_commits_multi h:3 p:12 q:30
    bc_curl_raw_content "# fake historical wget formula content at sha p"

    run "$BC_SCRIPT" install wget
    [ "$status" -eq 0 ]
    # brew shim was invoked with --force-bottle against the staged tap
    grep -qE "^install --force-bottle brew-cooldown/cooldown-[A-Za-z0-9]+/wget$" "$BC_BREW_LOG"
    # stderr surfaces the held-at-HEAD verdict and the rewind decision (exact form)
    echo "$output" | grep -qE "wget: HELD at HEAD; rewinding to p \(12d ago, "
    # raw.githubusercontent.com was hit for sha p specifically (not h, not q),
    # and the URL has no embedded whitespace (regression check for the IFS bug)
    grep -qE "https://raw\.githubusercontent\.com/Homebrew/homebrew-core/p/Formula/w/wget\.rb" "$BC_CURL_LOG"
    ! grep -qE "https://raw\.githubusercontent\.com/Homebrew/homebrew-core/h/" "$BC_CURL_LOG"
    ! grep -qE "raw\.githubusercontent\.com/Homebrew/homebrew-core/p [^/]" "$BC_CURL_LOG"
}

@test "S-15: malicious-then-reverted — rewind picks L, never materializes M" {
    # R at 4d ago (HEAD revert, not N-stable: age 4 < 7)
    # M at 7d ago (malicious, not N-stable: gap to R = 3 < 7)
    # L at 27d ago (prior legit, N-stable: gap to M = 20 ≥ 7) → picked
    bc_curl_commits_multi R:4 M:7 L:27
    bc_curl_raw_content "# legit prior content at sha L"

    run "$BC_SCRIPT" install wget
    [ "$status" -eq 0 ]
    # brew installed the rewound tap-qualified name
    grep -qE "^install --force-bottle brew-cooldown/cooldown-[A-Za-z0-9]+/wget$" "$BC_BREW_LOG"
    # CRITICAL SAFETY ASSERTION: M is never fetched as raw content
    ! grep -qE "raw\.githubusercontent\.com/Homebrew/homebrew-core/M/" "$BC_CURL_LOG"
    # The raw fetch targeted L specifically
    grep -qE "raw\.githubusercontent\.com/Homebrew/homebrew-core/L/Formula/w/wget\.rb" "$BC_CURL_LOG"
    # Log indicates rewind to L with exact age
    echo "$output" | grep -qE "wget: HELD at HEAD; rewinding to L \(27d ago, "
}

@test "S-16: continuous churn with no N-stable in window — held with distinct verdict" {
    # 5 commits, all within 5 days, all gaps ≤ 1d. None N-stable.
    bc_curl_commits_multi a:1 b:2 c:3 d:4 e:5

    run "$BC_SCRIPT" install wget
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi "no N-stable version found"
    # brew was NOT invoked for install
    ! grep -qE "^install " "$BC_BREW_LOG"
    # No raw fetch was attempted (we never got past the n-stable lookup)
    ! grep -q "raw.githubusercontent.com" "$BC_CURL_LOG"
}

@test "S-17: brew refuses missing bottle — brew-cooldown propagates failure without source build" {
    bc_curl_commits_multi h:3 p:12 q:30
    bc_curl_raw_content "# historical content"
    # Brew shim returns non-zero on install (simulating missing-bottle / CannotInstallFormulaError)
    export BC_BREW_EXIT=1

    run "$BC_SCRIPT" install wget
    [ "$status" -ne 0 ]
    # We invoked brew with --force-bottle (the only flag we add) — never with --build-from-source
    grep -qE "^install --force-bottle brew-cooldown/cooldown-[A-Za-z0-9]+/wget$" "$BC_BREW_LOG"
    ! grep -q -- "--build-from-source" "$BC_BREW_LOG"
    # Our wrapper logs the failure context
    echo "$output" | grep -qi "brew install failed for rewound wget"
}

@test "S-18: --no-rewind restores the pre-ADR-0008 hold-and-eligibility-date behavior" {
    # Same fixture as S-14 (an N-stable predecessor would have been available),
    # but --no-rewind opts out.
    bc_curl_commits_multi h:3 p:12 q:30

    run "$BC_SCRIPT" --no-rewind install wget
    [ "$status" -eq 1 ]
    echo "$output" | grep -qi "held"
    echo "$output" | grep -qi "eligible after"
    # brew was NOT invoked, no raw fetch was attempted
    ! grep -qE "^install " "$BC_BREW_LOG"
    ! grep -q "raw.githubusercontent.com" "$BC_CURL_LOG"
}

@test "S-19: BREW_COOLDOWN_NO_REWIND=1 has the same effect as --no-rewind" {
    bc_curl_commits_multi h:3 p:12 q:30
    export BREW_COOLDOWN_NO_REWIND=1

    run "$BC_SCRIPT" install wget
    [ "$status" -eq 1 ]
    echo "$output" | grep -qi "held"
    ! grep -qE "^install " "$BC_BREW_LOG"
    ! grep -q "raw.githubusercontent.com" "$BC_CURL_LOG"
}

@test "S-14b: --dry-run on a rewind path prints the brew argv with --force-bottle" {
    bc_curl_commits_multi h:3 p:12 q:30
    bc_curl_raw_content "# historical content"

    run "$BC_SCRIPT" --dry-run install wget
    [ "$status" -eq 0 ]
    # dry-run prints the brew argv to stdout (run_brew_spawn honors BC_DRY_RUN too)
    echo "$output" | grep -qE "^brew install --force-bottle brew-cooldown/cooldown-[A-Za-z0-9]+/wget$"
    # Brew shim was NOT invoked in dry-run mode
    ! grep -qE "^install " "$BC_BREW_LOG"
}

@test "S-14c: staged tap dir is cleaned up after the run (EXIT trap fires)" {
    bc_curl_commits_multi h:3 p:12 q:30
    bc_curl_raw_content "# historical content"

    run "$BC_SCRIPT" install wget
    [ "$status" -eq 0 ]
    # After the run, no homebrew-cooldown-* dir should remain under Library/Taps/brew-cooldown
    if [[ -d "${BC_BREW_REPO}/Library/Taps/brew-cooldown" ]]; then
        ! find "${BC_BREW_REPO}/Library/Taps/brew-cooldown" -maxdepth 1 -name 'homebrew-cooldown-*' | grep -q .
    fi
}

@test "S-20: rewind lookup error + BREW_COOLDOWN_FAIL_OPEN=1 lets current HEAD through" {
    # Single 3d-old commit so check_cooldown (1st commits API call) returns held.
    bc_curl_commits_multi h:3
    # The 2nd commits API call (try_rewind's fetch_commits_for_path) fails.
    export BC_CURL_COMMITS_FAIL_AFTER=1
    export BREW_COOLDOWN_FAIL_OPEN=1

    run "$BC_SCRIPT" install wget
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi "rewind lookup failed"
    echo "$output" | grep -q "BREW_COOLDOWN_FAIL_OPEN=1"
    # We installed the CURRENT HEAD (no --force-bottle, no tap-qualified name)
    grep -qE "^install wget$" "$BC_BREW_LOG"
    ! grep -q -- "--force-bottle" "$BC_BREW_LOG"
    # No raw fetch (rewind aborted before it got that far)
    ! grep -q "raw.githubusercontent.com" "$BC_CURL_LOG"
}

@test "S-20b: rewind lookup error without FAIL_OPEN is fail-closed (exit 2)" {
    bc_curl_commits_multi h:3
    export BC_CURL_COMMITS_FAIL_AFTER=1

    run "$BC_SCRIPT" install wget
    [ "$status" -eq 2 ]
    echo "$output" | grep -qi "fail-closed"
    echo "$output" | grep -qi "rewind lookup failed"
    # brew NOT invoked for install; raw fetch never attempted
    ! grep -qE "^install " "$BC_BREW_LOG"
    ! grep -q "raw.githubusercontent.com" "$BC_CURL_LOG"
}

@test "S-21: rewound audit log line carries sha, age, and iso in stable form" {
    bc_curl_commits_multi h:3 p:12 q:30
    bc_curl_raw_content "# historical content"

    run "$BC_SCRIPT" install wget
    [ "$status" -eq 0 ]
    # The full line is "<name>: HELD at HEAD; rewinding to <sha> (<age>d ago, <iso>)".
    # Assert every field shape: sha is a bare token (no embedded whitespace),
    # age is an integer followed by "d ago", iso ends with the literal Z.
    echo "$output" | grep -qE "wget: HELD at HEAD; rewinding to [A-Za-z0-9]+ \([0-9]+d ago, [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\)$"
    # And specifically the values matching our fixture (sha=p, age=12)
    echo "$output" | grep -qE "rewinding to p \(12d ago, "
}
