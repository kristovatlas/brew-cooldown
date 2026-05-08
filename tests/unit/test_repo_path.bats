#!/usr/bin/env bats

load ../test_helper

setup()    { bc_setup; bc_load_lib; }
teardown() { bc_teardown; }

@test "U-11: formula path uses Formula/<first>/<name>.rb" {
    run repo_path_for "wget" "formula"
    [ "$output" = "Formula/w/wget.rb" ]
}

@test "U-11b: formula path with @ in name" {
    run repo_path_for "gcc@13" "formula"
    [ "$output" = "Formula/g/gcc@13.rb" ]
}

@test "U-12: cask path with font- prefix uses Casks/font/" {
    run repo_path_for "font-fira-code" "cask"
    [ "$output" = "Casks/font/font-fira-code.rb" ]
}

@test "U-13: cask path with digit first char uses Casks/<digit>/" {
    run repo_path_for "0xed" "cask"
    [ "$output" = "Casks/0/0xed.rb" ]
}

@test "U-13b: regular cask path uses Casks/<first-letter>/" {
    run repo_path_for "firefox" "cask"
    [ "$output" = "Casks/f/firefox.rb" ]
}

@test "U-13c: unknown kind returns non-zero" {
    run repo_path_for "wget" "bogus"
    [ "$status" -ne 0 ]
}
