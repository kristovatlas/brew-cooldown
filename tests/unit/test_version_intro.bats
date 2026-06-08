#!/usr/bin/env bats
# Unit-spec rows U-19 through U-24 — ADR-0010 version-introduction picker.
#
# Two functions under test:
#   parse_commit_version <formula> <sha> <message>
#     → "<version>" if message matches "<formula> X.Y.Z" or
#       "<formula>: update X.Y.Z bottle.", else "unknown:<sha>"
#
#   find_version_introduction_eligible <days_n> <days_m> <formula>
#     reads "<sha> <iso> <message>" lines from stdin, applies both gates,
#     emits "<sha> <iso> <age_days>" of the most recent eligible version's
#     first-introduction commit; returns 1 if nothing eligible.

load ../test_helper

setup()    { bc_setup; bc_load_lib; }
teardown() { bc_teardown; }

# ---- parse_commit_version ----

@test "U-19: parse_commit_version recognizes 'wget 1.5.0' as a version bump" {
    run parse_commit_version wget abc1234 "wget 1.5.0"
    [ "$status" -eq 0 ]
    [ "$output" = "1.5.0" ]
}

@test "U-20: parse_commit_version recognizes 'wget: update 1.5.0 bottle.' as a bot rebuild (same version)" {
    run parse_commit_version wget abc1234 "wget: update 1.5.0 bottle."
    [ "$status" -eq 0 ]
    [ "$output" = "1.5.0" ]
}

@test "U-21: parse_commit_version returns 'unknown:<sha>' for any unrecognized message" {
    run parse_commit_version wget abc1234 "manual aarch64 fix for wget"
    [ "$status" -eq 0 ]
    [ "$output" = "unknown:abc1234" ]
}

@test "U-21b: parse_commit_version conservatively returns unknown for partial-pattern matches" {
    # "wget 1.5.0 (rc)" doesn't match the strict intro pattern (anchored $).
    run parse_commit_version wget abc1234 "wget 1.5.0 (rc)"
    [ "$status" -eq 0 ]
    [ "$output" = "unknown:abc1234" ]
}

@test "U-21c: parse_commit_version handles formula names containing regex metacharacters" {
    # gcc@13: '@' is literal in regex; no escaping needed but make sure it works.
    run parse_commit_version "gcc@13" abc1234 "gcc@13 13.2.0"
    [ "$status" -eq 0 ]
    [ "$output" = "13.2.0" ]
}

@test "U-21d: parse_commit_version handles formula names with '+' (must escape)" {
    # 'g++' contains '+' which is a regex quantifier; parser must escape.
    run parse_commit_version "g++" abc1234 "g++ 12.3.0"
    [ "$status" -eq 0 ]
    [ "$output" = "12.3.0" ]
}

@test "U-21e: parse_commit_version handles formula names with '.' (must escape)" {
    # Hypothetical 'foo.bar': '.' is any-char in regex.
    run parse_commit_version "foo.bar" abc1234 "foo.bar 1.0.0"
    [ "$status" -eq 0 ]
    [ "$output" = "1.0.0" ]
}

# ---- find_version_introduction_eligible ----

# Helper: feed "sha:days_ago:message" triples (newest first) into the picker.
vintro_run() {
    local days_n="$1" days_m="$2" formula="$3"; shift 3
    local out=""
    local triple rest sha days iso message
    for triple in "$@"; do
        sha="${triple%%:*}"
        rest="${triple#*:}"
        days="${rest%%:*}"
        message="${rest#*:}"
        iso=$(bc_iso_days_ago "$days")
        out+="${sha} ${iso} ${message}"$'\n'
    done
    printf '%s' "$out" | find_version_introduction_eligible "$days_n" "$days_m" "$formula"
}

@test "U-22: picker installs from version's first-introduction commit (not later rebuilds)" {
    # newest-first:
    #   c (rebuild 1.5.0, 1d ago)  — V=1.5.0
    #   b (intro 1.5.0,   1d ago)  — V=1.5.0 ← intro, age 1d
    #   a (intro 1.4.0,   8d ago)  — V=1.4.0 ← intro, age 8d, lifetime ~7d
    # N=7, M=1: V=1.5.0 fails gate (a) (intro 1d < 7d).
    # V=1.4.0: intro 8d ≥ 7 ✓, lifetime ~7d (gap to b) ≥ 1d ✓. ELIGIBLE.
    # Pick the most recent eligible = V=1.4.0; install from `a` (its intro).
    run vintro_run 7 1 wget \
        'c:1:wget: update 1.5.0 bottle.' \
        'b:1:wget 1.5.0' \
        'a:8:wget 1.4.0'
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^a\ .+\ 8$ ]]
}

@test "U-23: revert-within-hours scenario — V_mal fails lifetime gate, picker chooses V_legit (refined: installs from V_legit's LATEST in-V commit ≥N old, not earliest)" {
    # newest-first:
    #   z (intro V_legit, ~7d ago)  — re-introduction of V_legit (post-revert)
    #   y (intro V_mal,   7d ago)   — malicious intro
    #   x (intro V_legit, 10d ago)  — original V_legit intro
    # V_mal lifetime = z.date − y.date ≈ 0s (both at same whole-day iso).
    # V_legit: V_legit has commits z (7d) and x (10d). Under the bottle-
    # availability refinement, the picker installs from the LATEST in-V
    # commit that's ≥ N days old → z, not x. z is git-immutable, was at
    # HEAD continuously from the revert until now, and represents the
    # post-revert (clean) state. Safe.
    run vintro_run 7 1 wget \
        'z:7:wget 11.5.0' \
        'y:7:wget 11.9.0-mal' \
        'x:10:wget 11.5.0'
    [ "$status" -eq 0 ]
    # Picks V_legit's latest in-V commit ≥7d, which is z (not x)
    [[ "$output" =~ ^z\ .+\ 7$ ]]
    # CRITICAL SAFETY: never picks y (the malicious commit)
    [[ ! "$output" =~ ^y\  ]]
}

@test "U-24: all commits unrecognized → no eligible version (unknown:* is conservatively skipped regardless of individual age/lifetime)" {
    # Each commit becomes its own unknown:<sha> synthetic version. Even though
    # the oldest commit `a` would individually satisfy gate (a) (age 8d ≥ 7)
    # and could clear gate (b) on its own HEAD-time, the picker conservatively
    # refuses to select any unknown:<sha> version. Result: no eligible version.
    run vintro_run 7 1 wget \
        'e:1:manual fix 1' \
        'd:2:manual fix 2' \
        'c:3:manual fix 3' \
        'b:4:manual fix 4' \
        'a:8:manual fix 5'
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "U-24b: a mixed history with a single recognized old version picks it cleanly past intervening unknowns" {
    # Even with unrecognized commits in the walk-back, a recognized version
    # that satisfies both gates is still pickable. Tests that unknown commits
    # don't pollute the version-grouping for adjacent recognized ones.
    run vintro_run 7 1 wget \
        'e:1:manual hotfix x' \
        'd:1:wget 1.5.0' \
        'c:2:wget 1.5.0' \
        'b:8:wget 1.4.0' \
        'a:14:wget 1.3.0'
    [ "$status" -eq 0 ]
    # V=1.5.0 intro 2d < 7 ✗; V=1.4.0 intro 8d ≥ 7 ✓ → pick `b`.
    [[ "$output" =~ ^b\ .+\ 8$ ]]
}

@test "U-22b: gap exactly equal to N (boundary) qualifies under gate (a)" {
    # V=1.5.0's intro is exactly N=7 days ago, lifetime ≥ M=1.
    run vintro_run 7 1 wget \
        'b:0:wget 1.5.0' \
        'a:7:wget 1.4.0'
    [ "$status" -eq 0 ]
    # V=1.5.0 fails gate (a) (intro 0d < 7d).
    # V=1.4.0: intro 7d ≥ 7 ✓, lifetime 7d ≥ 1 ✓. Pick `a`.
    [[ "$output" =~ ^a\ .+\ 7$ ]]
}

@test "U-22c: picker prefers the most recently introduced *eligible* version" {
    # Both 1.4.0 (8d) and 1.3.0 (20d) are eligible; pick 1.4.0 (most recent intro).
    run vintro_run 7 1 wget \
        'c:1:wget 1.5.0' \
        'b:8:wget 1.4.0' \
        'a:20:wget 1.3.0'
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^b\ .+\ 8$ ]]
}

@test "U-22d: bot-rebuild commits group with their version (extend lifetime, don't reset)" {
    # V=1.4.0's lifetime spans (b → a) = 6 days, well above M=1d.
    # The rebuild commit `c` (same version) extends lifetime but doesn't
    # change the intro commit.
    run vintro_run 7 1 wget \
        'e:0:wget 1.5.0' \
        'd:0:wget 1.4.0 bottle should not appear here' \
        'c:1:wget: update 1.4.0 bottle.' \
        'b:7:wget 1.4.0' \
        'a:13:wget 1.3.0'
    # 1.5.0 intro 0d < 7 ✗.
    # 1.4.0 intro 7d ≥ 7 ✓, lifetime ≥ 1d ✓ → pick `b` (its intro), age 7d.
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^b\ .+\ 7$ ]]
}
