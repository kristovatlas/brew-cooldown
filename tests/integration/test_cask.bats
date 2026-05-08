#!/usr/bin/env bats
# Spec rows S-09, S-09b — cask flow.

load ../test_helper

setup()    { bc_setup; }
teardown() { bc_teardown; }

@test "S-09: cask 3d old is held when cooldown=7" {
    bc_curl_return_iso_days_ago 3
    run "$BC_SCRIPT" --cask install firefox
    [ "$status" -eq 1 ]
    echo "$output" | grep -qi "held"
    [ ! -s "$BC_BREW_LOG" ]
    # Verify the curl call went to homebrew-cask, not homebrew-core
    grep -q "homebrew-cask" "$BC_CURL_LOG"
    grep -q "Casks/f/firefox.rb" "$BC_CURL_LOG"
}

@test "S-09b: font-prefix cask uses Casks/font/ path" {
    bc_curl_return_iso_days_ago 30
    run "$BC_SCRIPT" --cask --dry-run install font-fira-code
    [ "$status" -eq 0 ]
    echo "$output" | grep -qE "^brew install --cask font-fira-code$"
    grep -q "Casks/font/font-fira-code.rb" "$BC_CURL_LOG"
}

@test "cask with --no-cooldown skips lookup and execs --cask" {
    run "$BC_SCRIPT" --no-cooldown --cask install firefox
    [ "$status" -eq 0 ]
    grep -qE "^install --cask firefox$" "$BC_BREW_LOG"
    [ ! -s "$BC_CURL_LOG" ]
}

@test "upgrade --cask without explicit names is unsupported in v1" {
    run "$BC_SCRIPT" --cask upgrade
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi "not supported"
}
