## Summary

<!-- One sentence: what does this PR do and why? -->

## Spec / docs

- [ ] If this changes behavior, I updated `docs/spec.md` (the Given/When/Then table)
- [ ] If this changes a recorded decision, I amended the relevant ADR in `docs/adr/` (Status: Superseded) and added a new one
- [ ] If this changes the threat model or what we protect against, I updated `docs/threat-model.md`
- [ ] If this changes data flow, I updated `docs/architecture.md` and `docs/architecture.mmd`

## Tests

- [ ] All new behaviors have a row in `docs/spec.md` and a corresponding bats test
- [ ] `bats -r tests/` is green locally
- [ ] I did not add any test that invokes real `brew install/upgrade/reinstall`

## Security

- [ ] No new fail-open paths
- [ ] No new commands run with shell-interpolated user input
- [ ] Config file changes are still allowlist-parsed, never `source`d
- [ ] No secrets are logged (token redaction still works)

## Test plan

<!-- How did you verify? Include any manual --dry-run output. -->
