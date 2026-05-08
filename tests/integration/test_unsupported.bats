#!/usr/bin/env bats
# Spec rows S-07, S-13. Anything not install/upgrade/reinstall is rejected.

load ../test_helper

setup()    { bc_setup; }
teardown() { bc_teardown; }

@test "S-07: search subcommand is rejected with helpful message" {
    run "$BC_SCRIPT" search wget
    [ "$status" -eq 1 ]
    echo "$output" | grep -qi "unsupported subcommand"
    echo "$output" | grep -qi "install"
    echo "$output" | grep -qi "upgrade"
    echo "$output" | grep -qi "reinstall"
    # No curl/brew calls
    [ ! -s "$BC_CURL_LOG" ]
    [ ! -s "$BC_BREW_LOG" ]
}

@test "S-07b: update subcommand is rejected (cooldown N/A but we don't pass through)" {
    run "$BC_SCRIPT" update
    [ "$status" -eq 1 ]
    echo "$output" | grep -qi "unsupported subcommand"
}

@test "S-07c: info, list, outdated, tap, cleanup are all rejected" {
    for cmd in info list outdated tap cleanup bundle; do
        run "$BC_SCRIPT" "$cmd"
        [ "$status" -eq 1 ]
        echo "$output" | grep -qi "unsupported subcommand"
    done
}

@test "S-13: third-party tap path is rejected at name validation" {
    run "$BC_SCRIPT" install some-user/tap/foo
    [ "$status" -eq 1 ]
    echo "$output" | grep -qi "invalid name"
    # No curl call — rejected before lookup
    [ ! -s "$BC_CURL_LOG" ]
}

@test "no subcommand prints usage and exits non-zero" {
    run "$BC_SCRIPT"
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi "USAGE"
}

@test "unknown flag is rejected" {
    run "$BC_SCRIPT" --bogus install wget
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi "unknown flag"
}
