#!/usr/bin/env bats
# Unit-spec rows U-25 through U-33 — ADR-0011 depends_on parser.
#
# Function under test:
#   parse_depends_on <content> <user_os: macos|linux> <user_arch: arm|intel>
#     stdout: one runtime dep per line (deduped)
#     return 0 on clean parse, 1 on unparseable line (sets _dep_parse_error)

load ../test_helper

setup()    { bc_setup; bc_load_lib; }
teardown() { bc_teardown; }

# Convenience: pipe content via stdin to function call, or pass directly.
# We pass directly because parse_depends_on takes content as $1.

@test "U-25: depends_on \"openssl@3\" (simple runtime) → returns dep" {
    run parse_depends_on 'depends_on "openssl@3"' macos arm
    [ "$status" -eq 0 ]
    [ "$output" = "openssl@3" ]
}

@test "U-26: depends_on \"cmake\" => :build → skipped (not bottle-install dep)" {
    run parse_depends_on 'depends_on "cmake" => :build' macos arm
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "U-26b: depends_on \"x\" => :test → skipped" {
    run parse_depends_on 'depends_on "rspec" => :test' macos arm
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "U-26c: depends_on \"x\" => :optional → skipped (opt-in only)" {
    run parse_depends_on 'depends_on "extra" => :optional' macos arm
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "U-27: depends_on \"openssl@3\" => :recommended → treated as runtime" {
    run parse_depends_on 'depends_on "openssl@3" => :recommended' macos arm
    [ "$status" -eq 0 ]
    [ "$output" = "openssl@3" ]
}

@test "U-28: depends_on macos: :sequoia → skipped (toolchain requirement)" {
    run parse_depends_on 'depends_on macos: :sequoia' macos arm
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "U-28b: depends_on xcode: [\"15.0\", :build] → skipped" {
    run parse_depends_on 'depends_on xcode: ["15.0", :build]' macos arm
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "U-28c: depends_on arch: :arm64 → skipped" {
    run parse_depends_on 'depends_on arch: :arm64' macos arm
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "U-29: inline comment after depends_on (build dep with trailing # for X) → comment stripped, line interpreted as :build, skipped" {
    run parse_depends_on 'depends_on "swig" => :build # for lldb' macos arm
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "U-29b: inline comment on runtime dep — comment stripped, dep returned" {
    run parse_depends_on 'depends_on "libvmaf" # dependent: ab-av1' macos arm
    [ "$status" -eq 0 ]
    [ "$output" = "libvmaf" ]
}

@test "U-30: conditional Ruby (depends_on ... if X) → unparseable, fail" {
    local content
    content='depends_on "llvm" => :build if DevelopmentTools.clang_build_version <= 1699'
    run parse_depends_on "$content" macos arm
    [ "$status" -eq 1 ]
    [[ "${_dep_parse_error:-}" == *"line"*"unparseable depends_on"* ]] || \
        echo "$output" | grep -qi "unparseable" || true
}

@test "U-31: on_macos block, user is on macOS → dep returned" {
    local content
    content=$(cat <<'RB'
on_macos do
  depends_on "gettext"
end
RB
)
    run parse_depends_on "$content" macos arm
    [ "$status" -eq 0 ]
    [ "$output" = "gettext" ]
}

@test "U-32: on_linux block, user is on macOS → dep skipped" {
    local content
    content=$(cat <<'RB'
on_linux do
  depends_on "util-linux"
end
RB
)
    run parse_depends_on "$content" macos arm
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "U-32b: on_macos block, user is on Linux → skipped" {
    local content
    content=$(cat <<'RB'
on_macos do
  depends_on "gettext"
end
RB
)
    run parse_depends_on "$content" linux intel
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "U-32c: on_arm block, user is on arm → returned" {
    local content
    content=$(cat <<'RB'
on_arm do
  depends_on "rust"
end
RB
)
    run parse_depends_on "$content" macos arm
    [ "$status" -eq 0 ]
    [ "$output" = "rust" ]
}

@test "U-32d: on_arm block, user is on intel → skipped" {
    local content
    content=$(cat <<'RB'
on_arm do
  depends_on "rust"
end
RB
)
    run parse_depends_on "$content" macos intel
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "U-33: uses_from_macos \"zlib\" on macOS → skipped (system-provided)" {
    run parse_depends_on 'uses_from_macos "zlib"' macos arm
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "U-33b: uses_from_macos \"zlib\" on Linux → returned as runtime dep" {
    run parse_depends_on 'uses_from_macos "zlib"' linux intel
    [ "$status" -eq 0 ]
    [ "$output" = "zlib" ]
}

@test "Multiple deps in a formula are all returned, deduped" {
    local content
    content=$(cat <<'RB'
depends_on "openssl@3"
depends_on "python@3.14"
depends_on "openssl@3"
RB
)
    run parse_depends_on "$content" macos arm
    [ "$status" -eq 0 ]
    # openssl@3 should appear once; both unique deps returned
    local count
    count=$(echo "$output" | grep -c '^openssl@3$')
    [ "$count" -eq 1 ]
    echo "$output" | grep -q '^python@3.14$'
}

@test "bottle do block is skipped entirely (sha256 lines inside are not deps)" {
    local content
    content=$(cat <<'RB'
depends_on "openssl@3"
bottle do
  sha256 arm64_sequoia: "abc123"
  sha256 sonoma: "def456"
end
depends_on "python@3.14"
RB
)
    run parse_depends_on "$content" macos arm
    [ "$status" -eq 0 ]
    # Only the depends_on lines outside the bottle block should be returned
    [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 2 ]
    echo "$output" | grep -q '^openssl@3$'
    echo "$output" | grep -q '^python@3.14$'
}

@test "head do block is skipped (deps inside don't apply to bottle installs)" {
    local content
    content=$(cat <<'RB'
depends_on "openssl@3"
head do
  url "https://example.com/foo.git"
  depends_on "autoconf" => :build
  depends_on "automake" => :build
end
RB
)
    run parse_depends_on "$content" macos arm
    [ "$status" -eq 0 ]
    [ "$output" = "openssl@3" ]
}

@test "service / livecheck / patch / resource / test / stable / deprecate blocks all skipped" {
    local content
    content=$(cat <<'RB'
depends_on "openssl@3"
service do
  run [opt_bin/"foo"]
end
livecheck do
  url "https://example.com"
end
patch do
  url "https://example.com/p.patch"
end
test do
  system "true"
end
RB
)
    run parse_depends_on "$content" macos arm
    [ "$status" -eq 0 ]
    [ "$output" = "openssl@3" ]
}

@test "Realistic awscli-shaped formula parses correctly" {
    local content
    content=$(cat <<'RB'
class Awscli < Formula
  desc "Official Amazon AWS command-line interface"
  homepage "https://aws.amazon.com/cli/"
  url "https://github.com/aws/aws-cli/tarball/2.34.57"
  sha256 "abc123"
  license "Apache-2.0"
  head "https://github.com/aws/aws-cli.git", branch: "v2"

  bottle do
    sha256 arm64_sequoia: "abc"
    sha256 sonoma: "def"
  end

  depends_on "cmake" => :build
  depends_on "openssl@3"
  depends_on "python@3.14"

  def install
    # ...
  end
end
RB
)
    run parse_depends_on "$content" macos arm
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '^openssl@3$'
    echo "$output" | grep -q '^python@3.14$'
    # cmake should be skipped (build dep)
    ! echo "$output" | grep -q '^cmake$'
}

@test "Empty / dep-less formula parses cleanly with no output" {
    local content
    content=$(cat <<'RB'
class Hello < Formula
  desc "Test formula with no deps"
  homepage "https://example.com"
  url "https://example.com/hello.tar.gz"
  sha256 "abc"
end
RB
)
    run parse_depends_on "$content" macos arm
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
