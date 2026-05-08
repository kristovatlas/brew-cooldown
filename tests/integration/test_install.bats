#!/usr/bin/env bats
# Spec rows S-01, S-02, S-04, S-04b, S-05, S-06.

load ../test_helper

setup()    { bc_setup; }
teardown() { bc_teardown; }

@test "S-01: install of an old formula execs brew install with that name" {
    bc_curl_return_iso_days_ago 90
    run "$BC_SCRIPT" --dry-run install wget
    [ "$status" -eq 0 ]
    # dry-run prints exact brew argv to stdout
    echo "$output" | grep -qE "^brew install wget$"
    # brew shim was NOT invoked (dry-run skips exec)
    [ ! -s "$BC_BREW_LOG" ]
}

@test "S-01b: without --dry-run, the brew shim records the call" {
    bc_curl_return_iso_days_ago 90
    run "$BC_SCRIPT" install wget
    [ "$status" -eq 0 ]
    grep -qE "^install wget$" "$BC_BREW_LOG"
}

@test "S-02: install of a brand-new formula is held with eligibility date" {
    bc_curl_return_iso_days_ago 1
    run "$BC_SCRIPT" install wget
    [ "$status" -eq 1 ]
    echo "$output" | grep -qi "held"
    echo "$output" | grep -qi "eligible after"
    [ ! -s "$BC_BREW_LOG" ]
}

@test "S-04: curl failure causes fail-closed exit 2" {
    export BC_CURL_EXIT=22
    run "$BC_SCRIPT" install wget
    [ "$status" -eq 2 ]
    echo "$output" | grep -qi "fail-closed"
    [ ! -s "$BC_BREW_LOG" ]
}

@test "S-04b: BREW_COOLDOWN_FAIL_OPEN=1 lets curl failures through" {
    export BC_CURL_EXIT=22
    export BREW_COOLDOWN_FAIL_OPEN=1
    run "$BC_SCRIPT" install wget
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi "fail_open"
    grep -qE "^install wget$" "$BC_BREW_LOG"
}

@test "S-05: invalid name is rejected before any curl/brew call" {
    run "$BC_SCRIPT" install 'wget; rm -rf /'
    [ "$status" -eq 1 ]
    echo "$output" | grep -qi "invalid name"
    [ ! -s "$BC_CURL_LOG" ]
    [ ! -s "$BC_BREW_LOG" ]
}

@test "S-06: --no-cooldown bypasses the check, warns, and execs brew" {
    bc_curl_return_iso_days_ago 1
    run "$BC_SCRIPT" --no-cooldown install wget
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi "cooldown disabled"
    grep -qE "^install wget$" "$BC_BREW_LOG"
    # Note: with --no-cooldown the script doesn't even hit curl
    [ ! -s "$BC_CURL_LOG" ]
}

@test "S-06b: BREW_COOLDOWN_DISABLE=1 has the same effect as --no-cooldown" {
    export BREW_COOLDOWN_DISABLE=1
    run "$BC_SCRIPT" install wget
    [ "$status" -eq 0 ]
    grep -qE "^install wget$" "$BC_BREW_LOG"
    [ ! -s "$BC_CURL_LOG" ]
}

@test "install with no args fails with usage" {
    run "$BC_SCRIPT" install
    [ "$status" -ne 0 ]
}

@test "install with --dry-run on held formula still exits 1" {
    bc_curl_return_iso_days_ago 1
    run "$BC_SCRIPT" --dry-run install wget
    [ "$status" -eq 1 ]
    echo "$output" | grep -qi "held"
}
