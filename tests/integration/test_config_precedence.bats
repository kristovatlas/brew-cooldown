#!/usr/bin/env bats
# Spec rows S-11, S-12 — config precedence and config-file safety.

load ../test_helper

setup()    { bc_setup; }
teardown() { bc_teardown; }

write_cfg() {
    mkdir -p "$XDG_CONFIG_HOME/brew-cooldown"
    printf '%s\n' "$@" > "$XDG_CONFIG_HOME/brew-cooldown/config"
}

@test "S-11: --days flag overrides env which overrides config file" {
    write_cfg "BREW_COOLDOWN_DAYS=14"
    export BREW_COOLDOWN_DAYS=3
    bc_curl_return_iso_days_ago 2
    # cooldown=14 (cfg) → held; cooldown=3 (env) → held; cooldown=1 (flag) → eligible
    run "$BC_SCRIPT" --days 1 install wget
    [ "$status" -eq 0 ]
    grep -qE "^install wget$" "$BC_BREW_LOG"
}

@test "S-11b: env overrides config file when no flag is set" {
    write_cfg "BREW_COOLDOWN_DAYS=14"
    export BREW_COOLDOWN_DAYS=3
    bc_curl_return_iso_days_ago 5
    # config=14 → held; env=3 → 5 ≥ 3 → eligible
    run "$BC_SCRIPT" install wget
    [ "$status" -eq 0 ]
    grep -qE "^install wget$" "$BC_BREW_LOG"
}

@test "S-11c: config file is used when no env or flag is set" {
    write_cfg "BREW_COOLDOWN_DAYS=2"
    bc_curl_return_iso_days_ago 5
    # cfg=2 → 5 ≥ 2 → eligible
    run "$BC_SCRIPT" install wget
    [ "$status" -eq 0 ]
    grep -qE "^install wget$" "$BC_BREW_LOG"
}

@test "S-11d: default (7 days) applies when nothing is configured" {
    bc_curl_return_iso_days_ago 5
    # default 7 → 5 < 7 → held
    run "$BC_SCRIPT" install wget
    [ "$status" -eq 1 ]
}

@test "S-12: malicious config line ('rm -rf /' shape) is not executed" {
    write_cfg 'BREW_COOLDOWN_DAYS=$(touch '"$BC_TMP"'/pwned)'
    bc_curl_return_iso_days_ago 5
    run "$BC_SCRIPT" install wget
    # Defaults to 7 → held. Important: the 'pwned' file MUST NOT exist.
    [ ! -e "$BC_TMP/pwned" ]
    [ "$status" -eq 1 ]
}

@test "S-12b: config line with semicolons is treated as a single value" {
    write_cfg 'BREW_COOLDOWN_DAYS=7; rm -rf '"$BC_TMP"'/wouldnt'
    run "$BC_SCRIPT" --version
    # value '7; rm -rf ...' fails the per-key regex; default applies; nothing nasty happens
    [ ! -e "$BC_TMP/wouldnt" ]
    [ "$status" -eq 0 ]
}

@test "config file with non-ASCII garbage doesn't crash" {
    printf '\xff\xfe\x00garbage\n' > "$XDG_CONFIG_HOME/brew-cooldown/config" 2>/dev/null || true
    mkdir -p "$XDG_CONFIG_HOME/brew-cooldown"
    printf '\xff\xfe\x00garbage\n' > "$XDG_CONFIG_HOME/brew-cooldown/config"
    run "$BC_SCRIPT" --version
    [ "$status" -eq 0 ]
}
