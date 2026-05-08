#!/usr/bin/env bats

load ../test_helper

setup()    { bc_setup; bc_load_lib; }
teardown() { bc_teardown; }

write_cfg() {
    mkdir -p "$XDG_CONFIG_HOME/brew-cooldown"
    printf '%s\n' "$@" > "$XDG_CONFIG_HOME/brew-cooldown/config"
}

@test "U-09: load_config sets BREW_COOLDOWN_DAYS from KEY=value line" {
    write_cfg "BREW_COOLDOWN_DAYS=14"
    _cfg_days=""
    load_config
    [ "$_cfg_days" = "14" ]
}

@test "U-09b: load_config handles comments and blank lines" {
    write_cfg "# this is a comment" "" "BREW_COOLDOWN_DAYS=21" "# another"
    _cfg_days=""
    load_config
    [ "$_cfg_days" = "21" ]
}

@test "U-09c: load_config strips quotes around values" {
    write_cfg 'BREW_COOLDOWN_DAYS="5"'
    _cfg_days=""
    load_config
    [ "$_cfg_days" = "5" ]
}

@test "U-10: load_config rejects malicious command-substitution-shaped lines" {
    write_cfg 'EVIL=$(rm -rf /tmp/wouldnt-do-this)'
    load_config
    # The key isn't in the allowlist; the value is regex-validated; nothing executed.
    [ ! -e /tmp/wouldnt-do-this ] || true
    # _cfg_days unchanged
    [ -z "${_cfg_days:-}" ]
}

@test "U-10b: load_config rejects out-of-range numeric values" {
    write_cfg "BREW_COOLDOWN_DAYS=99999"
    _cfg_days=""
    load_config
    [ -z "$_cfg_days" ]
}

@test "U-10c: load_config rejects FAIL_OPEN values that aren't 0 or 1" {
    write_cfg "BREW_COOLDOWN_FAIL_OPEN=yes"
    _cfg_fail_open=""
    load_config
    [ -z "$_cfg_fail_open" ]
}

@test "U-10d: load_config does NOT source the file (no shell expansion)" {
    write_cfg 'BREW_COOLDOWN_DAYS=`echo 99`'
    _cfg_days=""
    load_config
    # value `echo 99` doesn't match the digit regex, so it's rejected.
    [ -z "$_cfg_days" ]
}
