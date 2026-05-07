#!/usr/bin/env bats

load ../test_helper

setup()    { bc_setup; bc_load_lib; }
teardown() { bc_teardown; }

@test "U-01: validate_formula_name accepts plain lowercase" {
    run validate_formula_name "wget"
    [ "$status" -eq 0 ]
}

@test "U-01b: accepts dots, hyphens, plus, underscore, at" {
    run validate_formula_name "gcc@13"
    [ "$status" -eq 0 ]
    run validate_formula_name "x264-r3107"
    [ "$status" -eq 0 ]
    run validate_formula_name "libc++"
    [ "$status" -eq 0 ]
    run validate_formula_name "node.js"
    [ "$status" -eq 0 ]
    run validate_formula_name "0xed"
    [ "$status" -eq 0 ]
}

@test "U-02: rejects shell metacharacter" {
    run validate_formula_name "wget; rm"
    [ "$status" -eq 1 ]
    run validate_formula_name 'wget$(id)'
    [ "$status" -eq 1 ]
    run validate_formula_name "wget|cat"
    [ "$status" -eq 1 ]
    run validate_formula_name "wget&"
    [ "$status" -eq 1 ]
}

@test "U-03: rejects empty string" {
    run validate_formula_name ""
    [ "$status" -eq 1 ]
}

@test "U-04: rejects names longer than 100 chars" {
    local n; n=$(printf 'a%.0s' $(seq 1 101))
    run validate_formula_name "$n"
    [ "$status" -eq 1 ]
}

@test "U-05: rejects uppercase first character (we are stricter than Homebrew)" {
    run validate_formula_name "Pillow"
    [ "$status" -eq 1 ]
}

@test "U-05b: rejects third-party tap form" {
    run validate_formula_name "user/tap/foo"
    [ "$status" -eq 1 ]
}

@test "U-05c: rejects path traversal attempts" {
    run validate_formula_name "../etc/passwd"
    [ "$status" -eq 1 ]
    run validate_formula_name "wget/../passwd"
    [ "$status" -eq 1 ]
}
