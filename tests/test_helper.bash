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
    # URL-discriminated overrides (for rewind tests that need a different
    # response for the commits API call vs the raw.githubusercontent.com fetch).
    export BC_CURL_COMMITS_RESPONSE_FILE=""
    export BC_CURL_COMMITS_HTTP_CODE="200"
    export BC_CURL_RAW_RESPONSE_FILE=""
    export BC_CURL_RAW_HTTP_CODE="200"
    # If set to N, the first N api.github.com commits-API calls succeed and the
    # (N+1)-th and subsequent calls exit with BC_CURL_COMMITS_FAIL_EXIT.
    # Lets tests cover "check_cooldown succeeds, try_rewind lookup fails" —
    # check_cooldown is the 1st commits call, try_rewind is the 2nd.
    export BC_CURL_COMMITS_FAIL_AFTER=""
    export BC_CURL_COMMITS_FAIL_EXIT="22"
    export BC_BREW_OUTDATED_FILE=""
    export BC_BREW_EXIT="0"
    # Fake brew repository root, used by ensure_rewind_tap() to find Library/Taps.
    export BC_BREW_REPO="${BC_TMP}/brew-repo"
    mkdir -p "${BC_BREW_REPO}/Library/Taps"
    # Shimmed brew: log argv, answer `--repository`, emit `outdated` fixture,
    # exit with BC_BREW_EXIT.
    cat > "${BC_SHIM}/brew" <<'BREW_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${BC_BREW_LOG:-/dev/null}"
case "$1" in
    --repository)
        printf '%s\n' "${BC_BREW_REPO:-/tmp/brew-repo}"
        exit 0
        ;;
    outdated)
        if [[ -n "${BC_BREW_OUTDATED_FILE:-}" ]]; then
            cat "${BC_BREW_OUTDATED_FILE}"
        fi
        ;;
esac
exit "${BC_BREW_EXIT:-0}"
BREW_EOF
    chmod +x "${BC_SHIM}/brew"
    # Shimmed curl: log argv, choose a fixture by URL host:
    #   api.github.com       → BC_CURL_COMMITS_RESPONSE_FILE (falls back to BC_CURL_RESPONSE_FILE)
    #   raw.githubusercontent → BC_CURL_RAW_RESPONSE_FILE     (no fallback — must be set)
    #   otherwise            → BC_CURL_RESPONSE_FILE
    cat > "${BC_SHIM}/curl" <<'CURL_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${BC_CURL_LOG:-/dev/null}"
url=""
for a in "$@"; do
    case "$a" in https://*|http://*) url="$a" ;; esac
done
body_file="${BC_CURL_RESPONSE_FILE:-}"
http_code="${BC_CURL_HTTP_CODE:-200}"
case "$url" in
    *raw.githubusercontent.com*)
        if [[ -n "${BC_CURL_RAW_RESPONSE_FILE:-}" ]]; then
            body_file="${BC_CURL_RAW_RESPONSE_FILE}"
            http_code="${BC_CURL_RAW_HTTP_CODE:-200}"
        else
            body_file=""
        fi
        ;;
    *api.github.com*)
        if [[ -n "${BC_CURL_COMMITS_FAIL_AFTER:-}" ]]; then
            count_file="${BC_TMP:-/tmp}/_curl_commits_count"
            count=$(cat "$count_file" 2>/dev/null || echo 0)
            count=$((count + 1))
            echo "$count" > "$count_file"
            if (( count > BC_CURL_COMMITS_FAIL_AFTER )); then
                exit "${BC_CURL_COMMITS_FAIL_EXIT:-22}"
            fi
        fi
        if [[ -n "${BC_CURL_COMMITS_RESPONSE_FILE:-}" ]]; then
            body_file="${BC_CURL_COMMITS_RESPONSE_FILE}"
            http_code="${BC_CURL_COMMITS_HTTP_CODE:-200}"
        fi
        ;;
esac
if [[ -n "$body_file" && -f "$body_file" ]]; then
    cat "$body_file"
    printf '\n%s' "$http_code"
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
          BREW_COOLDOWN_DISABLE BREW_COOLDOWN_DEBUG HOMEBREW_GITHUB_API_TOKEN \
          BREW_COOLDOWN_NO_REWIND BREW_COOLDOWN_MAX_REWIND_COMMITS
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

# Build a "commits API" fixture body from a sequence of "sha:days_ago" pairs,
# newest first. Example: bc_make_commits_response_multi h:3 m:7 l:27
bc_make_commits_response_multi() {
    local first=1
    printf '['
    local pair sha days iso
    for pair in "$@"; do
        sha="${pair%%:*}"
        days="${pair##*:}"
        iso=$(bc_iso_days_ago "$days")
        if [[ $first -eq 1 ]]; then first=0; else printf ','; fi
        printf '{"sha":"%s","commit":{"committer":{"date":"%s","name":"x","email":"x@x"},"author":{"date":"%s"},"message":"c %s"}}' \
            "$sha" "$iso" "$iso" "$sha"
    done
    printf ']'
}

# Stage a multi-commit fixture for the commits-API curl path.
# Args: pairs of "sha:days_ago", newest first.
bc_curl_commits_multi() {
    local f="${BC_TMP}/commits_multi.json"
    bc_make_commits_response_multi "$@" > "$f"
    export BC_CURL_COMMITS_RESPONSE_FILE="$f"
    export BC_CURL_COMMITS_HTTP_CODE="200"
}

# Stage raw.githubusercontent.com content (the historical .rb body) for the
# rewind fetch_formula_content call.
bc_curl_raw_content() {
    local content="$1"
    local f="${BC_TMP}/raw_content.rb"
    printf '%s' "$content" > "$f"
    export BC_CURL_RAW_RESPONSE_FILE="$f"
    export BC_CURL_RAW_HTTP_CODE="200"
}
