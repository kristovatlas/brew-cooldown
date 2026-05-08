#!/usr/bin/env bats
# Spec row S-10 — GitHub rate-limit handling.

load ../test_helper

setup()    { bc_setup; }
teardown() { bc_teardown; }

@test "S-10: HTTP 403 with rate-limit body produces a distinct error" {
    export BC_CURL_RESPONSE_FILE="${BATS_TEST_DIRNAME}/../fixtures/rate_limit_403.json"
    export BC_CURL_HTTP_CODE="403"
    run "$BC_SCRIPT" install wget
    [ "$status" -eq 2 ]
    echo "$output" | grep -qi "rate limit"
    echo "$output" | grep -qi "BREW_COOLDOWN_GITHUB_TOKEN"
    [ ! -s "$BC_BREW_LOG" ]
}

@test "S-10b: HTTP 404 produces a distinct 'not found' error" {
    cat > "$BC_TMP/notfound.json" <<'EOF'
{"message":"Not Found","documentation_url":"https://docs.github.com/rest"}
EOF
    export BC_CURL_RESPONSE_FILE="$BC_TMP/notfound.json"
    export BC_CURL_HTTP_CODE="404"
    run "$BC_SCRIPT" install wget
    [ "$status" -eq 2 ]
    echo "$output" | grep -qi "not found"
    [ ! -s "$BC_BREW_LOG" ]
}

@test "S-10c: empty commits array (formula doesn't exist) errors" {
    export BC_CURL_RESPONSE_FILE="${BATS_TEST_DIRNAME}/../fixtures/empty_commits.json"
    export BC_CURL_HTTP_CODE="200"
    run "$BC_SCRIPT" install nonexistent-formula
    [ "$status" -eq 2 ]
    [ ! -s "$BC_BREW_LOG" ]
}

@test "S-10d: malformed JSON produces a clear error" {
    cat > "$BC_TMP/bad.json" <<'EOF'
this is not json
EOF
    export BC_CURL_RESPONSE_FILE="$BC_TMP/bad.json"
    export BC_CURL_HTTP_CODE="200"
    run "$BC_SCRIPT" install wget
    [ "$status" -eq 2 ]
    [ ! -s "$BC_BREW_LOG" ]
}
