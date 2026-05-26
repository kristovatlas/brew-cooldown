#!/usr/bin/env bats
# Unit-spec rows U-14 through U-18 — find_n_stable_commit (ADR-0008).
#
# A commit is N-stable iff:
#   - it has a later commit on the same path AND (later.date - this.date) ≥ N days
#   - OR it is HEAD AND (now - this.date) ≥ N days

load ../test_helper

setup()    { bc_setup; bc_load_lib; }
teardown() { bc_teardown; }

# Helper: feed "sha:days_ago" pairs (newest first) into find_n_stable_commit.
nstable_run() {
    local days="$1"; shift
    local out=""
    local pair sha d iso
    for pair in "$@"; do
        sha="${pair%%:*}"
        d="${pair##*:}"
        iso=$(bc_iso_days_ago "$d")
        out+="${sha} ${iso}"$'\n'
    done
    printf '%s' "$out" | find_n_stable_commit "$days"
}

@test "U-14: linear history — predecessor is N-stable (gap 9d ≥ N=7)" {
    # HEAD=h at 3d ago (HEAD age 3 < 7, not N-stable)
    # p at 12d ago (gap to HEAD = 9 ≥ 7, N-stable) → picked
    # q at 30d ago (older but p is the most recent N-stable)
    run nstable_run 7 h:3 p:12 q:30
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^p\ .+\ 12$ ]]
}

@test "U-15: malicious-then-reverted timeline — picks L, skips M" {
    # R at 4d ago (HEAD revert, age 4 < 7 → not N-stable)
    # M at 7d ago (malicious, gap to R = 3 < 7 → not N-stable)
    # L at 27d ago (prior legit, gap to M = 20 ≥ 7 → N-stable) → picked
    run nstable_run 7 R:4 M:7 L:27
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^L\ .+\ 27$ ]]
}

@test "U-15b: safety — M is never the picked target in the revert timeline" {
    run nstable_run 7 R:4 M:7 L:27
    [ "$status" -eq 0 ]
    # The picked SHA must not be the malicious one.
    [[ ! "$output" =~ ^M\  ]]
}

@test "U-16: no N-stable candidate within continuous churn" {
    # 5 commits with 1-day gaps — every gap < 7, no candidate.
    run nstable_run 7 a:1 b:2 c:3 d:4 e:5
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "U-17: single commit, age ≥ N (HEAD case from the general rule)" {
    run nstable_run 7 only:10
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^only\ .+\ 10$ ]]
}

@test "U-18: single commit, age < N — preserves today's hold behavior" {
    run nstable_run 7 only:3
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "U-14b: gap exactly equal to N is N-stable (inclusive boundary)" {
    # p at 7d ago, h at 0d ago — gap = 7. ≥ 7 → N-stable.
    run nstable_run 7 h:0 p:7
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^p\ .+\ 7$ ]]
}

nstable_raw() {
    # Args: days, then raw "sha iso" lines verbatim (no transformation).
    local days="$1"; shift
    printf '%s\n' "$@" | find_n_stable_commit "$days"
}

@test "U-14c: malformed iso line is skipped, not crashed on" {
    # First line has a bogus iso; should be skipped via the iso_to_epoch fallback
    # and the second (valid) line picked as the N-stable candidate.
    local good
    good=$(bc_iso_days_ago 30)
    run nstable_raw 7 "h not-an-iso" "p $good"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^p\ .+\ 30$ ]]
}
