#!/usr/bin/env bats

load ../test_helper

setup()    { bc_setup; bc_load_lib; }
teardown() { bc_teardown; }

@test "U-07: iso_to_epoch round-trips a known UTC timestamp" {
    local epoch; epoch=$(iso_to_epoch "2026-04-01T00:00:00Z")
    # 2026-04-01T00:00:00Z is well-known: compute via date for cross-check
    local check
    if check=$(date -u -d "2026-04-01T00:00:00Z" +%s 2>/dev/null); then :; else
        check=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-04-01T00:00:00Z" +%s)
    fi
    [ "$epoch" = "$check" ]
}

@test "U-08: age_days for a date 3 days ago returns 3" {
    local iso; iso=$(bc_iso_days_ago 3)
    run age_days "$iso"
    [ "$status" -eq 0 ]
    [ "$output" = "3" ]
}

@test "U-08b: age_days for a date 30 days ago returns 30" {
    local iso; iso=$(bc_iso_days_ago 30)
    run age_days "$iso"
    [ "$output" = "30" ]
}

@test "U-08c: age_days for a date 0 days ago returns 0" {
    local iso; iso=$(bc_iso_days_ago 0)
    run age_days "$iso"
    [ "$output" = "0" ]
}

@test "iso_to_epoch fails on garbage input" {
    run iso_to_epoch "not-a-date"
    [ "$status" -ne 0 ]
}
