#!/usr/bin/env bats
# Spec rows S-03, S-08.

load ../test_helper

setup()    { bc_setup; }
teardown() { bc_teardown; }

@test "S-03: upgrade no-args partial — eligible go through, held one is reported" {
    # Outdated list returned by brew shim
    export BC_BREW_OUTDATED_FILE="${BATS_TEST_DIRNAME}/../fixtures/outdated_v2.json"
    # Curl shim must respond per-formula. Easiest path: have it always return
    # the same response — but we want different answers per formula.
    # Use a smarter shim that picks based on the URL path.
    cat > "$BC_SHIM/curl" <<'CURL_EOF'
#!/usr/bin/env bash
# Per-test smart shim: hold "jq" (1d), allow "wget" (90d) and "curl" (90d).
url=""
for a in "$@"; do url="$a"; done   # last arg is the URL
if [[ "$url" == *"path=Formula/j/jq.rb"* ]]; then
    iso=$(date -u -d "@$(( $(date -u +%s) - 1*86400 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -r $(( $(date -u +%s) - 1*86400 )) +%Y-%m-%dT%H:%M:%SZ)
else
    iso=$(date -u -d "@$(( $(date -u +%s) - 90*86400 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -r $(( $(date -u +%s) - 90*86400 )) +%Y-%m-%dT%H:%M:%SZ)
fi
printf '[{"sha":"x","commit":{"committer":{"date":"%s"},"author":{"date":"%s"},"message":"x"}}]\n200' "$iso" "$iso"
exit 0
CURL_EOF
    chmod +x "$BC_SHIM/curl"

    run "$BC_SCRIPT" upgrade
    [ "$status" -eq 0 ]
    # Held one (jq) reported in stderr
    echo "$output" | grep -qi "jq"
    echo "$output" | grep -qi "held"
    # Final brew call: should include wget and curl, NOT jq
    last=$(grep -E "^upgrade " "$BC_BREW_LOG" | tail -1)
    [[ "$last" == *"wget"* ]]
    [[ "$last" == *"curl"* ]]
    [[ "$last" != *"jq"* ]]
}

@test "S-03b: upgrade no-args with empty outdated reports nothing to upgrade" {
    cat > "$BC_TMP/empty_outdated.json" <<'EOF'
{"formulae":[],"casks":[]}
EOF
    export BC_BREW_OUTDATED_FILE="$BC_TMP/empty_outdated.json"
    run "$BC_SCRIPT" upgrade
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi "nothing to upgrade"
    # only `outdated` was called, no `upgrade`
    grep -qE "^outdated " "$BC_BREW_LOG"
    ! grep -qE "^upgrade " "$BC_BREW_LOG"
}

@test "S-08: --dry-run upgrade prints exact brew command and does not exec" {
    bc_curl_return_iso_days_ago 90
    run "$BC_SCRIPT" --dry-run upgrade wget
    [ "$status" -eq 0 ]
    echo "$output" | grep -qE "^brew upgrade wget$"
    # No real brew exec; brew shim wasn't called for upgrade
    ! grep -qE "^upgrade " "$BC_BREW_LOG"
}

@test "S-08b: --dry-run install on cask prints brew install --cask <name>" {
    bc_curl_return_iso_days_ago 90
    run "$BC_SCRIPT" --dry-run --cask install firefox
    [ "$status" -eq 0 ]
    echo "$output" | grep -qE "^brew install --cask firefox$"
}
