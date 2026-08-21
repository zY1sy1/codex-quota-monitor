# Relay Currency Display Precision Design

## Goal

Display relay currency values with exactly two decimal places while preserving
the underlying numeric values, calculations, and compact formatting for
non-currency units.

## Design

Update the shared relay presentation number formatter in
`companion/Private/RelayPresentation.ps1` to select its format from the unit.
USD and CNY use the invariant fixed-point format `0.00`; request counts,
tokens, percentages, and unknown units retain the existing compact
`0.########` format. Amount and ratio labels already route through this
formatter, so Full, Compact, and Orb views remain consistent without changing
runtime data, caches, comparisons, or scheduling.

## Testing

Extend `tests/Unit/RelayPresentation.Tests.ps1` to cover rounding, integer
zero-padding, zero currency values, currency ratios, compact request counts,
and preservation of the original numeric result. Run the focused Pester test,
the complete PowerShell suite, installation, and live health checks.
