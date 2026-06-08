#!/usr/bin/env bats
# Spec rows S-23 through S-29 — ADR-0010 version-introduction default behavior
# (the new default rewind rule, and the `--strict-cooldown` opt-in fallback to
# ADR-0008 N-stable).

load ../test_helper

setup()    { bc_setup; }
teardown() { bc_teardown; }

@test "S-23: happy path — pnpm-shaped history, picks the version-introduction commit of the most recent eligible version" {
    # Commits newest first. Each version-bump is immediately followed by a
    # bot-rebuild commit for the same version (real BrewTestBot pattern).
    #   wget 1.5.0 (HEAD, 1d)             ← V=1.5.0, fails gate (a) (intro 1d < 7d)
    #   wget: update 1.4.0 bottle. (4d)    ← V=1.4.0
    #   wget 1.4.0 (4d)                    ← V=1.4.0 intro, age 4d? wait, with our test fixture
    #
    # Actually let me re-do: we need V=1.4.0 to have intro ≥ 7d. So:
    #   d (HEAD, 0d):  wget 1.5.0
    #   c (3d):        wget: update 1.4.0 bottle.
    #   b (8d):        wget 1.4.0
    #   a (20d):       wget 1.3.0
    # V=1.5.0: intro 0d < 7d → skip
    # V=1.4.0: intro 8d ≥ 7d ✓, lifetime (8d → 0d span minus 1.5.0's HEAD-time)
    #          really sum of HEAD-times of b and c = (8-3=5) + (3-0=3) = 8d ≥ 1d ✓
    # → pick `b`. Install from staged tap.
    bc_curl_commits_with_messages \
        'd:0:wget 1.5.0' \
        'c:3:wget: update 1.4.0 bottle.' \
        'b:8:wget 1.4.0' \
        'a:20:wget 1.3.0'
    bc_curl_raw_content "# historical wget content at sha b (1.4.0 intro)"

    run "$BC_SCRIPT" install wget
    [ "$status" -eq 0 ]
    # Brew shim invoked with --force-bottle against the staged tap
    grep -qE "^install --force-bottle brew-cooldown/cooldown-[A-Za-z0-9]+/wget$" "$BC_BREW_LOG"
    # Raw fetch targeted `b` specifically (V=1.4.0's first-introduction commit)
    grep -qE "raw\.githubusercontent\.com/Homebrew/homebrew-core/b/Formula/w/wget\.rb" "$BC_CURL_LOG"
    # Did NOT fetch the rebuild commit `c` even though it's the same version
    ! grep -qE "raw\.githubusercontent\.com/Homebrew/homebrew-core/c/" "$BC_CURL_LOG"
    # Stderr log mentions the rewind
    echo "$output" | grep -qE "wget: HELD at HEAD; rewinding to b \(8d ago, "
}

@test "S-24: revert-within-hours — V_mal fails lifetime gate, picker chooses V_legit, no malicious content fetched" {
    # Need a fresh HEAD so check_cooldown actually triggers rewind. Timeline:
    #   z   (HEAD, 1d): wget 11.5.0              ← V=11.5.0 (current HEAD, held by cooldown)
    #   z2  (8d):       wget 11.5.0              ← V=11.5.0 (re-intro by revert)
    #   y   (8d):       wget 11.9.0-mal          ← V_mal intro (attacker, same iso as z2 → V_mal lifetime ≈ 0s)
    #   x   (15d):      wget 11.5.0              ← V=11.5.0 (original legitimate intro)
    # V_mal lifetime = z2.date − y.date ≈ 0 (same whole-day iso). Fails gate (b) under M=1.
    # V=11.5.0 lifetime = 1d + 7d + 7d ≈ 15d. Intro = `x` at 15d. Both gates satisfied.
    # Pick V=11.5.0 (most-recent first-sighting in newest-first walk).
    # Install from `x` — the EARLIEST V=11.5.0 intro, not the re-intro `z2`.
    bc_curl_commits_with_messages \
        'z:1:wget 11.5.0' \
        'z2:8:wget 11.5.0' \
        'y:8:wget 11.9.0-mal' \
        'x:15:wget 11.5.0'
    bc_curl_raw_content "# legit V_legit content at sha x"

    run "$BC_SCRIPT" install wget
    [ "$status" -eq 0 ]
    # CRITICAL SAFETY ASSERTION: never fetch the attacker's commit
    ! grep -qE "raw\.githubusercontent\.com/Homebrew/homebrew-core/y/" "$BC_CURL_LOG"
    # Did fetch the legit V_legit first-introduction commit (the original, not the re-intro)
    grep -qE "raw\.githubusercontent\.com/Homebrew/homebrew-core/x/Formula/w/wget\.rb" "$BC_CURL_LOG"
    # And specifically NOT the re-intro `z2`, which is git-immutable but newer
    ! grep -qE "raw\.githubusercontent\.com/Homebrew/homebrew-core/z2/" "$BC_CURL_LOG"
}

@test "S-25: in-lifetime spoofed bot-rebuild attack — picker installs from version's earliest intro, not the spoofed in-lifetime commit" {
    # newest first:
    #   d (HEAD, 0d): wget 1.5.0                          ← V=1.5.0 (fresh, fails gate a)
    #   c (3d):       wget: update 1.4.0 bottle.          ← V=1.4.0 (spoofed/attacker)
    #   b (8d):       wget: update 1.4.0 bottle.          ← V=1.4.0 (also a rebuild-shaped)
    #   a (10d):      wget 1.4.0                          ← V=1.4.0 intro (legit)
    # Even though `c` has the recognized rebuild-pattern message and falls
    # within V=1.4.0's lifetime, the picker pins to `a` (the earliest in-V
    # commit, which is git-immutable and predates anything `c` could do).
    bc_curl_commits_with_messages \
        'd:0:wget 1.5.0' \
        'c:3:wget: update 1.4.0 bottle.' \
        'b:8:wget: update 1.4.0 bottle.' \
        'a:10:wget 1.4.0'
    bc_curl_raw_content "# legit V=1.4.0 intro content at sha a"

    run "$BC_SCRIPT" install wget
    [ "$status" -eq 0 ]
    # Must install from `a` (the earliest V=1.4.0 commit), not `c` or `b`
    grep -qE "raw\.githubusercontent\.com/Homebrew/homebrew-core/a/Formula/w/wget\.rb" "$BC_CURL_LOG"
    ! grep -qE "raw\.githubusercontent\.com/Homebrew/homebrew-core/c/" "$BC_CURL_LOG"
    ! grep -qE "raw\.githubusercontent\.com/Homebrew/homebrew-core/b/" "$BC_CURL_LOG"
}

@test "S-26: unrecognized commit messages — bucketed as unknown:*, conservatively never picked" {
    # All-unknown history: no commit's message matches either BrewTestBot
    # pattern. Picker skips all unknown:* versions. Result: no eligible
    # version, exits 1 with the held verdict.
    bc_curl_commits_with_messages \
        'e:1:hand-crafted maintainer commit 1' \
        'd:2:another non-bot commit' \
        'c:3:something else' \
        'b:4:more manual work' \
        'a:8:original handcrafted intro'

    run "$BC_SCRIPT" install wget
    [ "$status" -eq 1 ]
    # No raw fetch — we never picked an eligible version
    ! grep -q "raw.githubusercontent.com" "$BC_CURL_LOG"
    # No brew install invocation
    ! grep -qE "^install " "$BC_BREW_LOG"
    # Stderr surfaces the held verdict
    echo "$output" | grep -qi "held"
}

@test "S-26b: mixed recognized + unrecognized — picker walks past unknowns to the most recent recognized eligible version" {
    # e (1d): unrecognized hotfix
    # d (1d): wget 1.5.0          ← V=1.5.0 (fresh, fails gate a)
    # c (2d): wget 1.5.0          ← (same version, rebuild-ish but bare intro pattern; same V)
    # b (8d): wget 1.4.0          ← V=1.4.0 intro
    # a (14d): wget 1.3.0         ← V=1.3.0
    bc_curl_commits_with_messages \
        'e:1:manual hotfix' \
        'd:1:wget 1.5.0' \
        'c:2:wget 1.5.0' \
        'b:8:wget 1.4.0' \
        'a:14:wget 1.3.0'
    bc_curl_raw_content "# V=1.4.0 intro content"

    run "$BC_SCRIPT" install wget
    [ "$status" -eq 0 ]
    # Picked V=1.4.0's intro at `b`
    grep -qE "raw\.githubusercontent\.com/Homebrew/homebrew-core/b/" "$BC_CURL_LOG"
}

@test "S-27: --strict-cooldown opts in to the ADR-0008 N-stable rule" {
    # Same fixture as S-23 (which would normally pick V=1.4.0's intro).
    # With --strict-cooldown, falls back to N-stable: HEAD (d, 0d) is not
    # N-stable; previous (c, 3d) has gap to d = 3d < 7d, not N-stable;
    # previous (b, 8d) has gap to c = 5d, still < 7d, not N-stable;
    # previous (a, 20d) has gap to b = 12d ≥ 7d → N-stable.
    # → Pick `a`, not `b`.
    bc_curl_commits_with_messages \
        'd:0:wget 1.5.0' \
        'c:3:wget: update 1.4.0 bottle.' \
        'b:8:wget 1.4.0' \
        'a:20:wget 1.3.0'
    bc_curl_raw_content "# strict-cooldown picks an older commit"

    run "$BC_SCRIPT" --strict-cooldown install wget
    [ "$status" -eq 0 ]
    # Under N-stable, picks `a` (much older than `b` which the default would have picked)
    grep -qE "raw\.githubusercontent\.com/Homebrew/homebrew-core/a/Formula/w/wget\.rb" "$BC_CURL_LOG"
    ! grep -qE "raw\.githubusercontent\.com/Homebrew/homebrew-core/b/" "$BC_CURL_LOG"
}

@test "S-28: BREW_COOLDOWN_STRICT=1 env var has the same effect as --strict-cooldown" {
    bc_curl_commits_with_messages \
        'd:0:wget 1.5.0' \
        'c:3:wget: update 1.4.0 bottle.' \
        'b:8:wget 1.4.0' \
        'a:20:wget 1.3.0'
    bc_curl_raw_content "# strict via env"
    export BREW_COOLDOWN_STRICT=1

    run "$BC_SCRIPT" install wget
    [ "$status" -eq 0 ]
    grep -qE "raw\.githubusercontent\.com/Homebrew/homebrew-core/a/Formula/w/wget\.rb" "$BC_CURL_LOG"
}

@test "S-29: no eligible version under default rule — held with informative stderr" {
    # Continuous churn with all version intros within last N days.
    # Each version intro is 1-2 days apart; nothing satisfies gate (a).
    bc_curl_commits_with_messages \
        'd:0:wget 1.5.3' \
        'c:1:wget 1.5.2' \
        'b:2:wget 1.5.1' \
        'a:5:wget 1.5.0'

    run "$BC_SCRIPT" install wget
    [ "$status" -ne 0 ]
    # No raw fetch — nothing eligible
    ! grep -q "raw.githubusercontent.com" "$BC_CURL_LOG"
    # No brew install
    ! grep -qE "^install " "$BC_BREW_LOG"
    echo "$output" | grep -qi "held"
}
