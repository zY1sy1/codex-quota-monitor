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
        f"  <rect x=\"5\" y=\"5\" width=\"118\" height=\"118\" rx=\"29\" fill=\"#FFFFFF\" stroke=\"{colors['border']}\" stroke-width=\"4\"/>\n"
        f"  <circle cx=\"64\" cy=\"64\" r=\"41\" fill=\"none\" stroke=\"{colors['track']}\" stroke-width=\"12\"/>\n"
        f"  <path d=\"M64 23a41 41 0 1 1-37.9 56.5\" fill=\"none\" stroke=\"{arc_stroke}\" stroke-width=\"12\" stroke-linecap=\"round\"/>\n"
        f"  <path d=\"m47 51 13 13-13 13M66 78h18\" fill=\"none\" stroke=\"{colors['glyph']}\" stroke-width=\"7\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>\n"
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
    draw.rounded_rectangle((scaled(5), scaled(5), scaled(123), scaled(123)), radius=scaled(29), fill="#FFFFFF", outline=colors["border"], width=scaled(4))
    draw.ellipse((scaled(23), scaled(23), scaled(105), scaled(105)), outline=colors["track"], width=scaled(12))

    arc_points = []
    for step in range(161):
        angle = math.radians(-90 + (247.7 * step / 160))
        arc_points.append((64 + 41 * math.cos(angle), 64 + 41 * math.sin(angle)))
    if name == "white":
        draw_round_line(draw, arc_points, rgb(colors["arc_start"]), 12)
    else:
        for start, end in zip(arc_points, arc_points[1:]):
            midpoint_x = (start[0] + end[0]) / 2
            midpoint_y = (start[1] + end[1]) / 2
            draw_round_line(draw, [start, end], diagonal_gradient(rgb(colors["arc_start"]), rgb(colors["arc_end"]), midpoint_x, midpoint_y), 12)
        radius = scaled(6)
        for point in (arc_points[0], arc_points[-1]):
            x, y = scaled(point[0]), scaled(point[1])
            color = diagonal_gradient(rgb(colors["arc_start"]), rgb(colors["arc_end"]), point[0], point[1])
            draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=color)

    glyph = rgb(colors["glyph"])
    draw_round_line(draw, [(47, 51), (60, 64), (47, 77)], glyph, 7)
    draw_round_line(draw, [(66, 78), (84, 78)], glyph, 7)
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
