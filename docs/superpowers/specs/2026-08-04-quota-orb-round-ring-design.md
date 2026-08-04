# Quota Orb Round Ring Design

## Goal

Make the quota orb's progress arc and background track share one geometrically circular centerline at every percentage and supported display scale while preserving the selected visual treatment: a 6 px cyan stroke with rounded endpoints.

## Observed problem

The current 74% orb looks uneven because the two visible strokes do not share the same centerline radius. The gray `Ellipse` track has a 70×70 layout box and a 6 px stroke, so WPF insets its rendered centerline by half the stroke width and produces a 32 px radius. The cyan `Path` arc is generated explicitly with a 35 px radius. The cyan value arc therefore sits 3 px outside the gray track instead of covering it concentrically.

## Considered approaches

### A. Reduce the value arc to a 32 px radius

Reduce the generated cyan arc radius from 35 px to 32 px while keeping the track at 70×70.

- Produces a concentric ring inside the current 70×70 track box.
- Makes the visible cyan ring smaller and increases the gap to the orb edge.

### B. Expand the track to a 35 px centerline radius — selected

Increase the gray track layout from 70×70 to 76×76. With a 6 px stroke, WPF then renders its centerline diameter as 70 px, matching the existing cyan arc's radius of 35 px.

- Leaves the cyan arc geometry, endpoint behavior, percentage calculation, and center text unchanged.
- Preserves the stronger ring size selected in the browser comparison.
- Changes only the track's two layout dimensions.

### C. Replace the path with dash-based ellipse rendering

Render a complete ellipse and represent progress using dash length and offset.

- Uses an inherently circular base shape.
- Requires new percentage-to-circumference logic and more edge-case handling for 0% and 100%, adding unnecessary scope.

## Selected design

The orb keeps its existing 112×112 body. The gray track remains an `Ellipse`, but its layout becomes 76×76 so its 6 px stroke has a 35 px centerline radius. The value arc remains the existing radius-35 `Path` built from `PathFigure` and `ArcSegment`. Both strokes are centered by the parent grid and therefore share the same center and radius.

No changes are made to colors, text, controls, data selection, quota calculations, window placement, or display-mode behavior.

## Data and rendering flow

1. Presentation supplies `ProgressValue` between 0 and 100.
2. `Get-QuotaOrbArcGeometry` converts the percentage to a clockwise endpoint on a radius-35 circle.
3. `RenderFocus` creates the WPF arc geometry in the fixed 0–70 coordinate space.
4. The 76×76 `RingTrack` renders a radius-35 centerline behind the unchanged value arc.

Invalid or unavailable progress values continue to hide the value arc and display the existing fallback text.

## Testing

- Add integration regression assertions that the loaded `RingTrack` is 76×76; they must fail while it remains 70×70.
- Retain the existing geometry endpoint and rendering tests.
- Run the focused quota-orb integration tests, then the complete Pester suite.
- Regenerate the visual matrix and inspect dark/light orb output at 100% and 150% scale.
- Compare the 74% output with the supplied screenshot, checking circularity, round caps, centering, and clipping.

## Success criteria

- The 74% value arc is concentric with the track and has constant apparent curvature.
- Rounded endpoints remain visible and are not flattened or clipped.
- Low percentages remain on the same centerline as the complete track.
- The ring remains correct at 100% and 150% scale in both themes.
- Existing quota-orb behavior and all automated tests remain intact.
