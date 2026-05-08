# test_helper.bash — common bats setup for brew-cooldown.
#
# Usage in a .bats file:
#   load ../test_helper
#   setup() { bc_setup; }
#   teardown() { bc_teardown; }

# Path to the script under test
BC_SCRIPT="${BATS_TEST_DIRNAME}/../../bin/brew-cooldown"
# When called from tests/integration or tests/unit:
if [[ ! -f "$BC_SCRIPT" ]]; then
    BC_SCRIPT="${BATS_TEST_DIRNAME}/../bin/brew-cooldown"
fi

# Per-test scratch dir, plus a PATH-shimmed dir for fake brew/curl.
bc_setup() {
    BC_TMP="$(mktemp -d)"
    export BC_TMP
    BC_SHIM="${BC_TMP}/shimbin"
    mkdir -p "$BC_SHIM"
    # Capture file: tests assert on the exact argv that brew was invoked with.
    BC_BREW_LOG="${BC_TMP}/brew_calls.log"
    BC_CURL_LOG="${BC_TMP}/curl_calls.log"
    : > "$BC_BREW_LOG"
    : > "$BC_CURL_LOG"
    export BC_BREW_LOG BC_CURL_LOG
    # Default fixtures: empty (each test sets its own)
    export BC_CURL_RESPONSE_FILE=""
    export BC_CURL_HTTP_CODE="200"
    export BC_CURL_EXIT="0"
    export BC_BREW_OUTDATED_FILE=""
    export BC_BREW_EXIT="0"
    # Shimmed brew: log argv, optionally print fixture, exit with BC_BREW_EXIT.
    cat > "${BC_SHIM}/brew" <<'BREW_EOF'
#!/usr/bin/env bash
# shim brew: log argv, maybe emit fixture for `outdated`, exit with BC_BREW_EXIT.
printf '%s\n' "$*" >> "${BC_BREW_LOG:-/dev/null}"
if [[ "$1" == "outdated" && -n "${BC_BREW_OUTDATED_FILE:-}" ]]; then
    cat "${BC_BREW_OUTDATED_FILE}"
fi
exit "${BC_BREW_EXIT:-0}"
BREW_EOF
    chmod +x "${BC_SHIM}/brew"
    # Shimmed curl: log argv, emit fixture body + http_code if response file set.
    cat > "${BC_SHIM}/curl" <<'CURL_EOF'
#!/usr/bin/env bash
# shim curl: log argv. If BC_CURL_RESPONSE_FILE is set, emit that body and the
# http_code that brew-cooldown's curl invocation requested via -w '\n%{http_code}'.
# Always exits BC_CURL_EXIT.
printf '%s\n' "$*" >> "${BC_CURL_LOG:-/dev/null}"
# Detect if the caller passed -w '\n%{http_code}' (we always do)
if [[ -n "${BC_CURL_RESPONSE_FILE:-}" && -f "${BC_CURL_RESPONSE_FILE}" ]]; then
    cat "${BC_CURL_RESPONSE_FILE}"
    printf '\n%s' "${BC_CURL_HTTP_CODE:-200}"
fi
exit "${BC_CURL_EXIT:-0}"
CURL_EOF
    chmod +x "${BC_SHIM}/curl"
    # Prepend shim dir to PATH so `command brew` and curl pick it up.
    export PATH="${BC_SHIM}:${PATH}"
    # Isolate config: point XDG_CONFIG_HOME at the empty tmp dir so prod config
    # never bleeds into tests.
    export XDG_CONFIG_HOME="${BC_TMP}/xdg"
    mkdir -p "$XDG_CONFIG_HOME"
    # Clear any inherited brew-cooldown env that could pollute tests.
    unset BREW_COOLDOWN_DAYS BREW_COOLDOWN_GITHUB_TOKEN BREW_COOLDOWN_FAIL_OPEN \
          BREW_COOLDOWN_DISABLE BREW_COOLDOWN_DEBUG HOMEBREW_GITHUB_API_TOKEN
}

bc_teardown() {
    if [[ -n "${BC_TMP:-}" && -d "$BC_TMP" ]]; then
        rm -rf "$BC_TMP"
    fi
}

# Source the script in lib mode for unit tests that call functions directly.
bc_load_lib() {
    BREW_COOLDOWN_LIB_ONLY=1 source "$BC_SCRIPT"
}

# Build a "commits API" fixture body containing one commit at a given ISO date.
bc_make_commits_response() {
    local iso="$1"
    cat <<JSON
[{"sha":"abcdef","commit":{"committer":{"date":"$iso","name":"x","email":"x@x"},"author":{"date":"$iso"},"message":"some commit"}}]
JSON
}

# Format an ISO date N days ago (UTC).
bc_iso_days_ago() {
    local n="$1"
    local epoch
    epoch=$(( $(date -u +%s) - n * 86400 ))
    if date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; then return 0; fi
    date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ
}

# Set the curl shim to return the given commit-API JSON with HTTP 200.
bc_curl_return_iso_days_ago() {
    local n="$1"
    local iso; iso=$(bc_iso_days_ago "$n")
    local f="${BC_TMP}/commits.json"
    bc_make_commits_response "$iso" > "$f"
    export BC_CURL_RESPONSE_FILE="$f"
    export BC_CURL_HTTP_CODE="200"
    export BC_CURL_EXIT="0"
}

# Inspect the brew shim's log: returns the most recent recorded call.
bc_last_brew_call() {
    tail -n1 "$BC_BREW_LOG" 2>/dev/null || true
}
