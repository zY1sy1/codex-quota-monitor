# CC Switch Optional Template Type Compatibility Design

## Goal

Allow the CC Switch import dialog to discover valid usage-query rules when a
current CC Switch database omits the optional `usage_script.templateType`
field. The importer must keep its existing read-only and credential-isolation
boundaries.

## Confirmed Compatibility Gap

The local CC Switch database still contains the expected `providers` and
`provider_endpoints` tables. It has two enabled JavaScript usage rules. One
rule omits `usage_script.templateType`, while the current inspector requests
that value as a non-null Rust `String`. The resulting SQLite conversion error
causes discovery of the entire database to fail with
`CcSwitchSchemaUnsupported`.

`templateType` is conversion guidance, not executable input and not a
credential. A missing value does not make the usage script invalid.

## Design

The Rust database inspector will read `templateType` as an optional text value.
When it is absent or null, the inspector will emit the canonical non-secret
value `general`. Existing non-empty text values will be preserved.

The inspector will continue to require and validate provider identity,
application type, display name, enabled state, JavaScript language, script
code, timeout, and refresh interval. A present `templateType` with an
incompatible SQLite type will continue to fail closed rather than being
coerced.

No PowerShell controller, WPF view, provider schema, or source-link format
needs to change. The existing flow remains:

1. Open **Manage relays** and choose **Import from CC Switch**.
2. Select a discovered rule and endpoint.
3. Import the generated Generic draft into the editor.
4. Re-enter the API key in the monitor.
5. Trust the destination, run a live test, then save and enable the rule.

## Security Boundary

The inspector remains read-only and must not query or return
`providers.settings_config`, the complete `providers.meta` value,
`usage_script.apiKey`, request logs, rollups, cached balances, or session data.
It will not copy API keys, access tokens, cookies, user IDs, or other
credentials. Literal credential detection and code removal remain unchanged.

The compatibility change must not guess endpoints, modify the CC Switch
database, or make an imported rule active before the user supplies credentials
and completes a successful test.

## Error Handling

- Missing or null `templateType`: normalize to `general` and continue.
- Non-empty text `templateType`: preserve it.
- Present non-text `templateType`: return the existing sanitized
  `CcSwitchSchemaUnsupported` failure.
- Missing required fields, invalid field types, locked databases, oversized
  results, unsupported languages, and suspected embedded credentials retain
  their current behavior.
- One compatible rule with an omitted optional field must not prevent other
  valid rules from appearing.

## Testing And Acceptance

Development follows a red-green cycle:

1. Add a Rust fixture with two enabled rules, one with a normal `templateType`
   and one where the field is absent.
2. Confirm the new test fails because the current inspector rejects the
   absent value.
3. Implement optional parsing and the `general` default.
4. Verify both descriptors are returned and no forbidden credential sentinel
   appears in serialized output.
5. Add or retain a negative test proving a present non-text value fails closed.
6. Run Rust formatting/tests, the full PowerShell suite, packaged-host
   verification, and installation health checks.

After packaging and installation, the real local CC Switch database must be
inspected successfully and the import dialog must list both currently enabled
rules without exposing credentials. The installed monitor must remain healthy
and official quota monitoring must remain live.
