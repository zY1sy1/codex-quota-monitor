# Quota Orb Round Ring Design

## Goal

Make the quota orb's progress arc remain a geometrically circular, visually smooth ring at every percentage and supported display scale while preserving the selected visual treatment: a 6 px cyan stroke with rounded endpoints.

## Observed problem

The current 74% orb renders an uneven arc that looks vertically and horizontally distorted. The arc geometry itself is generated from a constant 35 px radius, but the WPF `Path` displaying it has a fixed 70×70 layout size and leaves `Stretch` at its default value, `Fill`. WPF therefore rescales the bounds of each partial arc independently to fill the layout box. Because a partial arc does not always occupy a square natural bounding box, the display transform can turn the circular geometry into an elliptical or uneven-looking ring.

## Considered approaches

### A. Preserve the arc geometry and disable stretching — selected

Set the progress `Path` to `Stretch="None"`, retaining the existing 70×70 coordinate system, 35 px radius, 6 px stroke, and rounded caps.

- Minimal change at the rendering boundary where the distortion is introduced.
- Keeps the existing percentage-to-arc calculation and presentation API.
- Preserves the visual weight selected in the comparison page.

### B. Use uniform scaling

Set `Stretch="Uniform"` so X and Y are scaled equally.

- Prevents elliptical distortion.
- Still scales and repositions short arcs according to their changing natural bounds, making low percentages inconsistent.

### C. Replace the path with dash-based ellipse rendering

Render a complete ellipse and represent progress using dash length and offset.

- Uses an inherently circular base shape.
- Requires new percentage-to-circumference logic and more edge-case handling for 0% and 100%, adding unnecessary scope.

## Selected design

The orb keeps its existing 112×112 body and the ring keeps its existing 70×70 visual area. The track remains an `Ellipse`. The value arc remains the existing `Path` built from `PathFigure` and `ArcSegment`, but the path no longer stretches its data to fit changing partial-arc bounds. Both track and value arc therefore use the same fixed center and radius.

No changes are made to colors, text, controls, data selection, quota calculations, window placement, or display-mode behavior.

## Data and rendering flow

1. Presentation supplies `ProgressValue` between 0 and 100.
2. `Get-QuotaOrbArcGeometry` converts the percentage to a clockwise endpoint on a radius-35 circle.
3. `RenderFocus` creates the WPF arc geometry in the fixed 0–70 coordinate space.
4. The `RingValue` path renders that geometry without layout stretching.

Invalid or unavailable progress values continue to hide the value arc and display the existing fallback text.

## Testing

- Add an integration regression assertion that the loaded `RingValue` uses `Stretch=None`; it must fail before the XAML change.
- Retain the existing geometry endpoint and rendering tests.
- Run the focused quota-orb integration tests, then the complete Pester suite.
- Regenerate the visual matrix and inspect dark/light orb output at 100% and 150% scale.
- Compare the 74% output with the supplied screenshot, checking circularity, round caps, centering, and clipping.

## Success criteria

- The 74% value arc is concentric with the track and has constant apparent curvature.
- Rounded endpoints remain visible and are not flattened or clipped.
- Low percentages do not expand or shift to fill the ring area.
- The ring remains correct at 100% and 150% scale in both themes.
- Existing quota-orb behavior and all automated tests remain intact.
