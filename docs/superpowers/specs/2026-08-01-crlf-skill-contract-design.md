# CRLF-Tolerant Skill Contract Test

## Context

The merged `main` branch passes the quota-monitor runtime and integration tests, but one skill-policy contract assertion fails when the repository is checked out with Windows CRLF line endings. The same Git blobs pass from the older LF-only worktree. Two multiline regular expressions anchor policy sentences with `$` and therefore leave a trailing carriage return unmatched under CRLF.

## Chosen approach

Keep the skill content and repository line-ending policy unchanged. Update only the two line-anchored policy patterns in `tests/Unit/SkillContract.Tests.ps1` so they accept an optional carriage return before the line ending.

Add a deterministic regression assertion that converts the skill text to CRLF in memory and requires the policy contract to accept it. This makes the bug reproducible even when tests run from an LF checkout.

## Scope

- Modify `tests/Unit/SkillContract.Tests.ps1` only.
- Preserve all existing positive and negative policy checks.
- Do not change plugin runtime behavior, `SKILL.md`, installation state, or user data.
- Do not introduce a repository-wide `.gitattributes` policy.

## Verification

1. Confirm the new CRLF regression assertion fails before the regex fix.
2. Apply the minimal optional-carriage-return change.
3. Run `SkillContract.Tests.ps1` and confirm all focused assertions pass.
4. Run the full unit and integration suite and require all 354 tests plus the new regression assertion to pass.
5. Confirm `git diff --check` and the working-tree scope.
