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

@test "U-11c: formula starting with 'lib' uses Formula/lib/ subdir" {
    run repo_path_for "libassuan" "formula"
    [ "$output" = "Formula/lib/libassuan.rb" ]
}

@test "U-11d: 'liblinear' (a non-library lib*-named formula) also uses Formula/lib/" {
    # homebrew-core groups everything matching lib* under Formula/lib/ regardless
    # of whether it's actually a library — the subdir is a name-prefix convention,
    # not a semantic one.
    run repo_path_for "liblinear" "formula"
    [ "$output" = "Formula/lib/liblinear.rb" ]
}

@test "U-11e: formula starting with 'l' but not 'lib' uses Formula/l/" {
    run repo_path_for "lua" "formula"
    [ "$output" = "Formula/l/lua.rb" ]
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
