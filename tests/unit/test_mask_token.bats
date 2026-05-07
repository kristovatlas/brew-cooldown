#!/usr/bin/env bats

load ../test_helper

setup()    { bc_setup; bc_load_lib; }
teardown() { bc_teardown; }

@test "U-06: redacts ghp_ tokens" {
    out=$(mask_token "got error: ghp_abc123def456ghi789jkl")
    [[ "$out" != *"ghp_abc123def456ghi789jkl"* ]]
    [[ "$out" == *"[REDACTED]"* ]]
}

@test "U-06b: redacts github_pat tokens" {
    out=$(mask_token "github_pat_AAAAAAAAAAAAAAAAAAAA_BBBBBBBBBBBBBBBBBBBBBBBBBBBB")
    [[ "$out" == *"[REDACTED]"* ]]
    [[ "$out" != *"github_pat_AAAA"* ]]
}

@test "U-06c: redacts Authorization: Bearer ..." {
    out=$(mask_token "Authorization: Bearer abcXYZ123")
    [[ "$out" == *"[REDACTED]"* ]]
    [[ "$out" != *"abcXYZ123"* ]]
}

@test "U-06d: leaves non-token text alone" {
    out=$(mask_token "this is fine")
    [ "$out" = "this is fine" ]
}
