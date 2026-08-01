"""Generate the quota-monitor shortcut icons from one deterministic source."""

from __future__ import annotations

import argparse
import math
from pathlib import Path
from typing import Final

from PIL import Image, ImageDraw


VIEW_SIZE: Final = 128
ICO_SIZES: Final = (16, 24, 32, 48, 64, 128, 256)
SUPERSAMPLE: Final = 4
Point = tuple[float, float]

PLATE_ORIGIN: Final[Point] = (5, 5)
PLATE_SIZE: Final = VIEW_SIZE - (2 * PLATE_ORIGIN[0])
PLATE_CORNER_RADIUS: Final = 29
PLATE_STROKE_WIDTH: Final = 4

GAUGE_CENTER: Final[Point] = (64, 64)
GAUGE_RADIUS: Final = 41
GAUGE_TRACK_WIDTH: Final = 12

ARC_START: Final[Point] = (GAUGE_CENTER[0], GAUGE_CENTER[1] - GAUGE_RADIUS)
ARC_END_DELTA: Final[Point] = (-37.9, 56.5)
ARC_END: Final[Point] = (ARC_START[0] + ARC_END_DELTA[0], ARC_START[1] + ARC_END_DELTA[1])
ARC_STROKE_WIDTH: Final = 12
ARC_SEGMENTS: Final = 160

GLYPH_CHEVRON: Final[tuple[Point, Point, Point]] = ((47, 51), (60, 64), (47, 77))
GLYPH_BASELINE: Final[tuple[Point, Point]] = ((66, 78), (84, 78))
GLYPH_STROKE_WIDTH: Final = 7

VARIANTS: Final = {
    "white": {
        "border": "#D7DDE5",
        "track": "#E7EBF0",
        "arc_start": "#64748B",
        "arc_end": "#64748B",
        "glyph": "#1F2937",
    },
    "white-blue": {
        "border": "#BFDBFE",
        "track": "#DBEAFE",
        "arc_start": "#60A5FA",
        "arc_end": "#2563EB",
        "glyph": "#1E3A8A",
    },
}


def number(value: float) -> str:
    """Format source-coordinate values for the exact SVG contract."""
    return str(int(value)) if float(value).is_integer() else str(value)


def arc_path() -> str:
    """Serialize the shared arc geometry as its SVG path data."""
    return (
        f"M{number(ARC_START[0])} {number(ARC_START[1])}"
        f"a{number(GAUGE_RADIUS)} {number(GAUGE_RADIUS)} 0 1 1"
        f"{number(ARC_END_DELTA[0])} {number(ARC_END_DELTA[1])}"
    )


def glyph_path() -> str:
    """Serialize the shared terminal glyph geometry as its SVG path data."""
    start, corner, end = GLYPH_CHEVRON
    first_delta = (corner[0] - start[0], corner[1] - start[1])
    second_delta = (end[0] - corner[0], end[1] - corner[1])
    baseline_start, baseline_end = GLYPH_BASELINE
    return (
        f"m{number(start[0])} {number(start[1])}"
        f" {number(first_delta[0])} {number(first_delta[1])}"
        f"{number(second_delta[0])} {number(second_delta[1])}"
        f"M{number(baseline_start[0])} {number(baseline_start[1])}"
        f"h{number(baseline_end[0] - baseline_start[0])}"
    )


def svg_document(name: str) -> str:
    """Return the exact SVG document for a named icon variant."""
    colors = VARIANTS[name]
    defs = ""
    arc_stroke = colors["arc_start"]
    if name == "white-blue":
        defs = (
            "  <defs>\n"
            "    <linearGradient id=\"quotaArc\" x1=\"0\" y1=\"0\" x2=\"1\" y2=\"1\">\n"
            "      <stop stop-color=\"#60A5FA\"/>\n"
            "      <stop offset=\"1\" stop-color=\"#2563EB\"/>\n"
            "    </linearGradient>\n"
            "  </defs>\n"
        )
        arc_stroke = "url(#quotaArc)"
    return (
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 128 128\" role=\"img\" aria-label=\"Quota monitor gauge\">\n"
        f"{defs}"
        f"  <rect x=\"{number(PLATE_ORIGIN[0])}\" y=\"{number(PLATE_ORIGIN[1])}\" width=\"{number(PLATE_SIZE)}\" height=\"{number(PLATE_SIZE)}\" rx=\"{number(PLATE_CORNER_RADIUS)}\" fill=\"#FFFFFF\" stroke=\"{colors['border']}\" stroke-width=\"{number(PLATE_STROKE_WIDTH)}\"/>\n"
        f"  <circle cx=\"{number(GAUGE_CENTER[0])}\" cy=\"{number(GAUGE_CENTER[1])}\" r=\"{number(GAUGE_RADIUS)}\" fill=\"none\" stroke=\"{colors['track']}\" stroke-width=\"{number(GAUGE_TRACK_WIDTH)}\"/>\n"
        f"  <path d=\"{arc_path()}\" fill=\"none\" stroke=\"{arc_stroke}\" stroke-width=\"{number(ARC_STROKE_WIDTH)}\" stroke-linecap=\"round\"/>\n"
        f"  <path d=\"{glyph_path()}\" fill=\"none\" stroke=\"{colors['glyph']}\" stroke-width=\"{number(GLYPH_STROKE_WIDTH)}\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>\n"
        "</svg>\n"
    )


def rgb(value: str) -> tuple[int, int, int]:
    """Convert a six-digit hex paint value to RGB."""
    return (int(value[1:3], 16), int(value[3:5], 16), int(value[5:7], 16))


def scaled(value: float, factor: int = SUPERSAMPLE) -> int:
    """Scale source units for the supersampled canvas."""
    return round(value * factor)


def draw_round_line(draw: ImageDraw.ImageDraw, points: list[tuple[float, float]], fill: tuple[int, int, int], width: float) -> None:
    """Draw a polyline with round caps and joins in source coordinates."""
    scaled_points = [(scaled(x), scaled(y)) for x, y in points]
    scaled_width = scaled(width)
    draw.line(scaled_points, fill=fill, width=scaled_width, joint="curve")
    radius = scaled_width / 2
    for x, y in scaled_points:
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=fill)


def diagonal_gradient(start: tuple[int, int, int], end: tuple[int, int, int], x: float, y: float) -> tuple[int, int, int]:
    """Interpolate from the top-left to bottom-right of the source canvas."""
    progress = max(0.0, min(1.0, (x + y) / (2 * VIEW_SIZE)))
    return (
        round(start[0] + (end[0] - start[0]) * progress),
        round(start[1] + (end[1] - start[1]) * progress),
        round(start[2] + (end[2] - start[2]) * progress),
    )


def render_icon(name: str, size: int) -> Image.Image:
    """Render one RGBA icon at a requested ICO frame size."""
    colors = VARIANTS[name]
    canvas = Image.new("RGBA", (scaled(VIEW_SIZE), scaled(VIEW_SIZE)), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    plate_end = (PLATE_ORIGIN[0] + PLATE_SIZE, PLATE_ORIGIN[1] + PLATE_SIZE)
    draw.rounded_rectangle(
        (scaled(PLATE_ORIGIN[0]), scaled(PLATE_ORIGIN[1]), scaled(plate_end[0]), scaled(plate_end[1])),
        radius=scaled(PLATE_CORNER_RADIUS),
        fill="#FFFFFF",
        outline=colors["border"],
        width=scaled(PLATE_STROKE_WIDTH),
    )
    gauge_box = (
        GAUGE_CENTER[0] - GAUGE_RADIUS,
        GAUGE_CENTER[1] - GAUGE_RADIUS,
        GAUGE_CENTER[0] + GAUGE_RADIUS,
        GAUGE_CENTER[1] + GAUGE_RADIUS,
    )
    draw.ellipse(tuple(scaled(value) for value in gauge_box), outline=colors["track"], width=scaled(GAUGE_TRACK_WIDTH))

    arc_points = []
    start_angle = math.atan2(ARC_START[1] - GAUGE_CENTER[1], ARC_START[0] - GAUGE_CENTER[0])
    end_angle = math.atan2(ARC_END[1] - GAUGE_CENTER[1], ARC_END[0] - GAUGE_CENTER[0])
    for step in range(ARC_SEGMENTS + 1):
        angle = start_angle + ((end_angle - start_angle) * step / ARC_SEGMENTS)
        arc_points.append((GAUGE_CENTER[0] + GAUGE_RADIUS * math.cos(angle), GAUGE_CENTER[1] + GAUGE_RADIUS * math.sin(angle)))
    arc_points[0] = ARC_START
    arc_points[-1] = ARC_END
    if name == "white":
        draw_round_line(draw, arc_points, rgb(colors["arc_start"]), ARC_STROKE_WIDTH)
    else:
        for start, end in zip(arc_points, arc_points[1:]):
            midpoint_x = (start[0] + end[0]) / 2
            midpoint_y = (start[1] + end[1]) / 2
            draw_round_line(draw, [start, end], diagonal_gradient(rgb(colors["arc_start"]), rgb(colors["arc_end"]), midpoint_x, midpoint_y), ARC_STROKE_WIDTH)
        radius = scaled(ARC_STROKE_WIDTH / 2)
        for point in (arc_points[0], arc_points[-1]):
            x, y = scaled(point[0]), scaled(point[1])
            color = diagonal_gradient(rgb(colors["arc_start"]), rgb(colors["arc_end"]), point[0], point[1])
            draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=color)

    glyph = rgb(colors["glyph"])
    draw_round_line(draw, list(GLYPH_CHEVRON), glyph, GLYPH_STROKE_WIDTH)
    draw_round_line(draw, list(GLYPH_BASELINE), glyph, GLYPH_STROKE_WIDTH)
    return canvas.resize((size, size), Image.Resampling.LANCZOS)


def generate(output_dir: Path) -> None:
    """Write the SVG and ICO assets for every supported variant."""
    output_dir.mkdir(parents=True, exist_ok=True)
    for name in VARIANTS:
        svg_path = output_dir / f"codex-quota-monitor-{name}.svg"
        svg_path.write_text(svg_document(name), encoding="utf-8", newline="\n")
        frames = [render_icon(name, size) for size in ICO_SIZES]
        base = frames[-1]
        base.save(
            output_dir / f"codex-quota-monitor-{name}.ico",
            format="ICO",
            sizes=[(size, size) for size in ICO_SIZES],
            append_images=frames[:-1],
        )


def main() -> None:
    """Parse arguments and generate icon assets."""
    parser = argparse.ArgumentParser(description="Generate quota monitor shortcut icons.")
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    generate(args.output_dir)


if __name__ == "__main__":
    main()
