# ADR-0003: Fail-closed by default on errors

**Status:** Accepted

## Context

What should `brew-cooldown` do when it can't determine a formula's age — network error, GitHub rate limit, malformed JSON, formula not found in homebrew-core?

Two options:

- **Fail open**: treat "I don't know" as "probably fine, run brew anyway."
- **Fail closed**: treat "I don't know" as "refuse the operation."

The user is a security engineer who explicitly said *"security practices must be impeccable."* The whole point of `brew-cooldown` is defense-in-depth against supply-chain compromise. Failing open under any error condition negates the entire control: a sufficiently motivated attacker could simply target the API path that lookups depend on.

## Decision

**Fail-closed by default.** Any error in the lookup path (curl exit non-zero, HTTP status not 200, missing/empty `commit.committer.date`, JSON parse error, rate-limit response) refuses the operation with exit code 2 and a clear stderr message describing the underlying cause.

A single environment variable, `BREW_COOLDOWN_FAIL_OPEN=1`, flips this for users who explicitly accept the trade-off. When set, errors log a loud warning to stderr and then `exec brew` as if the cooldown check had passed.

## Consequences

**Accepted positives:**

- Security-by-default. No silent fall-through.
- Clear failure mode is debuggable (the error message names the root cause).
- The bypass switch exists for users who need it; it's opt-in and noisy.

**Accepted negatives:**

- Users on flaky networks or who hit rate limits will see refusals. Mitigation: clear error messages with remediation hints (e.g., set a token, retry later).
- A user who gets frustrated with refusals may set `BREW_COOLDOWN_FAIL_OPEN=1` permanently and forget. We accept this — it's their machine; informed consent.

## Alternatives considered

- **Fail-open default with a "strict" opt-in** — rejected: the most common configuration is the most secure one. Most users will not flip the switch either way; the default determines the security posture for the population.
- **Differential behavior** (fail-closed on rate-limit, fail-open on parse errors) — rejected as too clever; users can't reason about it.
- **Cache the last-known-good age** — would let us survive transient errors but introduces a stale-cache poisoning vector. Out of scope for v1.
