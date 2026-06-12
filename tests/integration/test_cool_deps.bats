#!/usr/bin/env bats
# Spec rows S-30 through S-36 — ADR-0011 transitive-dep cool (default-on).
# These tests opt back IN to dep cooling (test_helper sets the opt-out by
# default for the rest of the suite).

load ../test_helper

setup() {
    bc_setup
    # ADR-0011 default is on; flip the opt-out back off for these tests
    unset BREW_COOLDOWN_NO_COOL_DEPS
}
teardown() { bc_teardown; }

# Fixture for a simple "alpha → beta" dep tree.
# alpha is the top-level (eligible at HEAD)
# beta is a transitive dep (HEAD fresh, will need pre-install via subprocess)
setup_alpha_beta_fixture() {
    # alpha: HEAD eligible (14d old)
    bc_set_commits_for alpha aaaa01:14:"alpha 1.0.0"
    bc_set_raw_for alpha "$(cat <<'RB'
class Alpha < Formula
  desc "Test top-level"
  url "https://example.com/alpha.tar.gz"
  sha256 "feedface"
  depends_on "beta"
end
RB
)"
    # beta: HEAD held (3d old), with N-stable predecessor at 10d
    bc_set_commits_for beta bb02:3:"beta 1.5.0" bb01:10:"beta 1.4.0"
    # The staged (rewound) beta content — what brew-cooldown's subprocess writes
    bc_set_raw_for beta "$(cat <<'RB'
class Beta < Formula
  desc "Test leaf dep"
  url "https://example.com/beta.tar.gz"
  sha256 "deadbeef"
end
RB
)"
}

@test "S-30: top-level eligible, sole dep eligible at HEAD too → no subprocess, plain brew install" {
    # alpha eligible at HEAD; its dep gamma is also eligible at HEAD (12d old).
    # gamma's own subtree is still walked (its content is fetched and parsed),
    # but gamma itself needs no pre-install and has no deps of its own.
    bc_set_commits_for alpha aaaa01:14:"alpha 1.0.0"
    bc_set_raw_for alpha "$(cat <<'RB'
class Alpha < Formula
  url "https://example.com/a.tar.gz"
  sha256 "abc"
  depends_on "gamma"
end
RB
)"
    bc_set_commits_for gamma gg01:12:"gamma 2.0.0"
    bc_set_raw_for gamma "$(cat <<'RB'
class Gamma < Formula
  url "https://example.com/g.tar.gz"
  sha256 "def"
end
RB
)"

    run "$BC_SCRIPT" install alpha
    [ "$status" -eq 0 ]
    # brew install was invoked once, for the top-level only (no force-bottle)
    grep -qE "^install alpha$" "$BC_BREW_LOG"
    ! grep -qE "force-bottle" "$BC_BREW_LOG"
    # gamma's subtree WAS walked: its raw content was fetched
    grep -qE "raw\.githubusercontent\.com/Homebrew/homebrew-core/HEAD/Formula/g/gamma\.rb" "$BC_CURL_LOG"
    # No tap directory staged (no rewind, no subprocess install)
    if [[ -d "${BC_BREW_REPO}/Library/Taps/brew-cooldown" ]]; then
        ! find "${BC_BREW_REPO}/Library/Taps/brew-cooldown" -maxdepth 1 -name 'homebrew-cooldown-*' | grep -q .
    fi
}

@test "S-31b: fresh grandchild under an eligible uninstalled dep is still cooled (subtree walk)" {
    # alpha (eligible) → beta (NOT installed, eligible at HEAD) → gamma (NOT
    # installed, FRESH). Without the subtree walk, brew would install gamma
    # ungated as part of installing beta during alpha's install. The walk
    # must descend through eligible-but-uninstalled beta and pre-cool gamma.
    bc_set_commits_for alpha aaaa01:14:"alpha 1.0.0"
    bc_set_raw_for alpha "$(cat <<'RB'
class Alpha < Formula
  url "https://example.com/a.tar.gz"
  sha256 "abc"
  depends_on "beta"
end
RB
)"
    # beta: eligible at HEAD (12d), has its own dep gamma
    bc_set_commits_for beta bb01:12:"beta 2.0.0"
    bc_set_raw_for beta "$(cat <<'RB'
class Beta < Formula
  url "https://example.com/b.tar.gz"
  sha256 "bcd"
  depends_on "gamma"
end
RB
)"
    # gamma: fresh at HEAD (1d), with a version-introduction candidate at 10d
    bc_set_commits_for gamma gg02:1:"gamma 1.1.0" gg01:10:"gamma 1.0.0"
    bc_set_raw_for gamma "$(cat <<'RB'
class Gamma < Formula
  url "https://example.com/g.tar.gz"
  sha256 "def"
end
RB
)"

    run "$BC_SCRIPT" install alpha
    [ "$status" -eq 0 ]
    # gamma was pre-installed via recursive subprocess (rewind + force-bottle)
    grep -qE "^install --force-bottle brew-cooldown/cooldown-[A-Za-z0-9]+/gamma$" "$BC_BREW_LOG"
    # beta itself was NOT pre-installed (it's eligible; brew handles it)
    ! grep -qE "force-bottle .*/beta$" "$BC_BREW_LOG"
    # top-level alpha installed after gamma
    grep -qE "^install alpha$" "$BC_BREW_LOG"
    local gamma_line alpha_line
    gamma_line=$(grep -nE "^install --force-bottle .*/gamma$" "$BC_BREW_LOG" | head -1 | cut -d: -f1)
    alpha_line=$(grep -nE "^install alpha$" "$BC_BREW_LOG" | head -1 | cut -d: -f1)
    [ -n "$gamma_line" ] && [ -n "$alpha_line" ] && [ "$gamma_line" -lt "$alpha_line" ]
}

@test "S-30b: top-level eligible, sole dep already installed → no subprocess, dep untouched (firewall not auditor)" {
    bc_set_commits_for alpha aaaa01:14:"alpha 1.0.0"
    bc_set_raw_for alpha "$(cat <<'RB'
class Alpha < Formula
  url "https://example.com/a.tar.gz"
  sha256 "abc"
  depends_on "gamma"
end
RB
)"
    # gamma is "already installed" per the shim's BC_BREW_INSTALLED_NAMES;
    # brew-cooldown should NOT touch it regardless of its current homebrew-core age.
    bc_mark_installed gamma
    # gamma's HEAD is fresh — under the auditor framing this'd matter, but under
    # the firewall framing it doesn't (already installed = grandfathered).
    bc_set_commits_for gamma gg01:1:"gamma 2.0.0"

    run "$BC_SCRIPT" install alpha
    [ "$status" -eq 0 ]
    # No tap created, no force-bottle invocation, no rewind activity for gamma
    if [[ -d "${BC_BREW_REPO}/Library/Taps/brew-cooldown" ]]; then
        ! find "${BC_BREW_REPO}/Library/Taps/brew-cooldown" -maxdepth 1 -name 'homebrew-cooldown-*' | grep -q .
    fi
    ! grep -qE "force-bottle" "$BC_BREW_LOG"
    grep -qE "^install alpha$" "$BC_BREW_LOG"
}

@test "S-31: top-level eligible, dep fresh in homebrew-core → recursive brew-cooldown install of the dep, then top-level" {
    setup_alpha_beta_fixture

    run "$BC_SCRIPT" install alpha
    [ "$status" -eq 0 ]
    # Subprocess installed beta via the rewind path with --force-bottle
    grep -qE "^install --force-bottle brew-cooldown/cooldown-[A-Za-z0-9]+/beta$" "$BC_BREW_LOG"
    # Top-level alpha then installed via plain brew install
    grep -qE "^install alpha$" "$BC_BREW_LOG"
    # Order: beta should have been installed before alpha
    local beta_line alpha_line
    beta_line=$(grep -nE "^install --force-bottle .*/beta$" "$BC_BREW_LOG" | head -1 | cut -d: -f1)
    alpha_line=$(grep -nE "^install alpha$" "$BC_BREW_LOG" | head -1 | cut -d: -f1)
    [ -n "$beta_line" ] && [ -n "$alpha_line" ] && [ "$beta_line" -lt "$alpha_line" ]
}

@test "S-33: top-level's depends_on contains conditional Ruby → parser refuses, install fails closed" {
    bc_set_commits_for alpha aaaa01:14:"alpha 1.0.0"
    bc_set_raw_for alpha "$(cat <<'RB'
class Alpha < Formula
  url "https://example.com/a.tar.gz"
  sha256 "abc"
  depends_on "llvm" => :build if DevelopmentTools.clang_build_version <= 1699
  depends_on "openssl@3"
end
RB
)"

    run "$BC_SCRIPT" install alpha
    [ "$status" -ne 0 ]
    # Stderr names the unparseable form and points at --no-cool-deps
    echo "$output" | grep -qi "depends_on parser failed"
    echo "$output" | grep -q "no-cool-deps"
    # brew install was NOT invoked
    ! grep -qE "^install " "$BC_BREW_LOG"
}

@test "S-34: --no-cool-deps bypasses the dep walk entirely; top-level installs even with unparseable depends_on" {
    bc_set_commits_for alpha aaaa01:14:"alpha 1.0.0"
    bc_set_raw_for alpha "$(cat <<'RB'
class Alpha < Formula
  depends_on "llvm" => :build if DevelopmentTools.clang_build_version <= 1699
  depends_on "openssl@3"
end
RB
)"

    run "$BC_SCRIPT" --no-cool-deps install alpha
    [ "$status" -eq 0 ]
    grep -qE "^install alpha$" "$BC_BREW_LOG"
    # NO subprocess invocation for any dep; NO raw.githubusercontent fetch
    # was attempted (skipped before content fetch)
    ! grep -q "raw.githubusercontent.com" "$BC_CURL_LOG"
}

@test "S-34b: BREW_COOLDOWN_NO_COOL_DEPS=1 env var has the same effect" {
    bc_set_commits_for alpha aaaa01:14:"alpha 1.0.0"
    bc_set_raw_for alpha "$(cat <<'RB'
class Alpha < Formula
  depends_on "x" => :build if some_condition?
end
RB
)"
    export BREW_COOLDOWN_NO_COOL_DEPS=1

    run "$BC_SCRIPT" install alpha
    [ "$status" -eq 0 ]
    grep -qE "^install alpha$" "$BC_BREW_LOG"
}

@test "S-36: pre-installed dep subprocess fails → top-level install is fail-stopped, never invoked" {
    # alpha eligible, beta needs pre-install — but beta has no commits at all
    # (commits API returns empty list, leading to cooldown lookup error).
    bc_set_commits_for alpha aaaa01:14:"alpha 1.0.0"
    bc_set_raw_for alpha "$(cat <<'RB'
class Alpha < Formula
  depends_on "beta"
end
RB
)"
    # beta is not installed; its commits return empty (formula doesn't exist
    # in homebrew-core from the lookup's POV).
    bc_set_commits_for beta
    # (empty triple list → no commits in response — fetch_latest_commit_date
    # returns "empty commit list" error → fail-closed)

    run "$BC_SCRIPT" install alpha
    [ "$status" -ne 0 ]
    # beta's cooldown lookup failed → propagated → alpha install never attempted
    ! grep -qE "^install alpha$" "$BC_BREW_LOG"
    echo "$output" | grep -qi "fail"
}

@test "S-37: parent's --days flag is authoritative for dep subprocesses even when it equals the compiled default and the config file disagrees" {
    # Config file says 3 days; the user passes --days 7 (== compiled default).
    # Pre-fix, the propagation diffed against the compiled default, passed
    # nothing, and the child re-read the config → deps cooled at 3 days.
    # beta is 5d old: fresh under the parent's 7, eligible under the config's
    # 3. Correct behavior: parent classifies beta fresh → subprocess install →
    # child (with propagated DAYS=7) rewinds beta to its 20d-old intro and
    # installs via --force-bottle. Buggy behavior: child plain-installs
    # current beta (`install beta` in the brew log).
    mkdir -p "$XDG_CONFIG_HOME/brew-cooldown"
    printf 'BREW_COOLDOWN_DAYS=3\n' > "$XDG_CONFIG_HOME/brew-cooldown/config"

    bc_set_commits_for alpha aaaa01:14:"alpha 1.0.0"
    bc_set_raw_for alpha "$(cat <<'RB'
class Alpha < Formula
  url "https://example.com/a.tar.gz"
  sha256 "abc"
  depends_on "beta"
end
RB
)"
    bc_set_commits_for beta bb02:5:"beta 1.1.0" bb01:20:"beta 1.0.0"
    bc_set_raw_for beta "$(cat <<'RB'
class Beta < Formula
  url "https://example.com/b.tar.gz"
  sha256 "bcd"
end
RB
)"

    run "$BC_SCRIPT" --days 7 install alpha
    [ "$status" -eq 0 ]
    # Child must have cooled beta (rewound, force-bottle) — NOT plain-installed it
    grep -qE "^install --force-bottle brew-cooldown/cooldown-[A-Za-z0-9]+/beta$" "$BC_BREW_LOG"
    ! grep -qE "^install beta$" "$BC_BREW_LOG"
}

@test "S-38: --dry-run with a fresh dep performs NO real installs anywhere (child inherits dry-run)" {
    # Pre-fix, main() clobbered the inherited BC_DRY_RUN, so the dep
    # subprocess REALLY installed during a parent --dry-run.
    bc_set_commits_for alpha aaaa01:14:"alpha 1.0.0"
    bc_set_raw_for alpha "$(cat <<'RB'
class Alpha < Formula
  url "https://example.com/a.tar.gz"
  sha256 "abc"
  depends_on "beta"
end
RB
)"
    bc_set_commits_for beta bb02:1:"beta 1.1.0" bb01:10:"beta 1.0.0"
    bc_set_raw_for beta "$(cat <<'RB'
class Beta < Formula
  url "https://example.com/b.tar.gz"
  sha256 "bcd"
end
RB
)"

    run "$BC_SCRIPT" --dry-run install alpha
    [ "$status" -eq 0 ]
    # The child printed its would-run argv (stdout), the parent printed its own
    echo "$output" | grep -qE "^brew install --force-bottle brew-cooldown/cooldown-[A-Za-z0-9]+/beta$"
    echo "$output" | grep -qE "^brew install alpha$"
    # CRITICAL: no install of ANY kind reached the brew shim
    ! grep -qE "^install " "$BC_BREW_LOG"
}

@test "S-34c: opt-out applies even when top-level itself needs rewind (cool_deps walk skipped on both rewound and survivor sets)" {
    # alpha HEAD fresh → would rewind; with --no-cool-deps, no dep walk on
    # alpha's staged content even though staging happened.
    bc_set_commits_for alpha aaaa02:1:"alpha 2.0.0" aaaa01:10:"alpha 1.0.0"
    bc_set_raw_for alpha "$(cat <<'RB'
class Alpha < Formula
  depends_on "beta"
end
RB
)"
    # beta would have been fresh if we tried to cool it — but we shouldn't
    bc_set_commits_for beta bb01:1:"beta 1.0.0"

    run "$BC_SCRIPT" --no-cool-deps install alpha
    [ "$status" -eq 0 ]
    # alpha installed via rewind path
    grep -qE "^install --force-bottle brew-cooldown/cooldown-[A-Za-z0-9]+/alpha$" "$BC_BREW_LOG"
    # No subprocess for beta (no force-bottle for beta in the log)
    ! grep -qE "force-bottle .*/beta$" "$BC_BREW_LOG"
}
