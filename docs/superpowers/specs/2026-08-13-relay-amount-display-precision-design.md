# Relay Amount Display Precision Design

## Goal

Display relay amount values with exactly two decimal places while preserving
the underlying numeric values and all quota calculations.

## Design

Update the existing `Format-RelayPresentationNumber` helper in
`companion/Private/RelayPresentation.ps1` from a variable-precision format to
the invariant fixed-point format `0.00`. All relay amount and ratio labels
already route through this helper, so Full, Compact, and Orb views remain
consistent without changing runtime data, caches, comparisons, or scheduling.

## Testing

Extend `tests/Unit/RelayPresentation.Tests.ps1` to cover rounding, integer
zero-padding, zero values, and ratio formatting. Assertions must also retain
the original numeric result fields to prove this is a presentation-only
change. Run the focused Pester test, the full PowerShell suite, package
verification, and installed health checks.
