#!/usr/bin/env python3
"""Measures where a Settings pane's rows put their text and controls, and draws
the shared lines on the screenshot.

  Tools/settings-guides.py <out dir> <pane.png>...

Reads the pane PNGs Tools/gallery-export.sh writes (pane-<name>.png, 610 pt
wide). For every row of every card it finds the title's left edge, each
element on the title line with its kind and right edge, the row's height, how
far the accessory's vertical center is from the control's, and how many lines
of text sit under the title. Writes <out dir>/<pane>-guides.png and
<out dir>/measurements.md; edges are in points from the pane's left edge.

A gate: exits 1 when a row breaks a rule of the Settings kit. Every control
ends on its pane's control line and every accessory centers on its column;
an accessory's center is within a pixel of its control's; rows with the same
number of lines under the title are one height; and no row has more than one
line under its title.
"""

import sys
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

PANE_POINTS = 610
# Two colors count as one within this much per channel.
SAME = 3
# Elements on a title line closer than this are one element (a word gap is 4 pt).
ELEMENT_GAP = 9.0
# A row's edge is off its pane's line beyond this.
OFF_LINE = 1.5
# An accessory is off its control's center, or a row off its kind's height, beyond this.
OFF_CENTER = 0.5
OFF_HEIGHT = 1.0
# A card's first and last rows are this much shorter than a row between two separators.
CARD_EDGE = 4.5
# A control's own pixels differ from the card by more than this; its soft shadow differs by less.
SOLID = 16
# A control drawn disabled never differs from the card by this much, so its edges cannot be read.
FAINT = 24
# How far above and below the title line a control reaches: a push button is 24 pt tall.
REACH = 9.0
# How far past the card's title edge a title starts when a mark sits before it: the mark's
# column and the gap after it (SettingsMetrics.markWidth + accessoryGap).
MARK_INDENT = 24.0
# A row taller than this holds a block (a chart, a list it opened), which the height rule skips.
BLOCK_HEIGHT = 70.0


@dataclass
class Element:
    left: float
    right: float
    height: float
    density: float
    middle: float = 0
    strength: int = 255
    kind: str = "text"


@dataclass
class Row:
    card: int
    top: float
    height: float
    title_center: float
    elements: list[Element]
    lines_under: int
    widest_under: float

    @property
    def is_marked(self) -> bool:
        """Whether a mark sits before the title: a dot, a drive."""
        return len(self.elements) > 1 and self.elements[0].kind == "mark" and self.elements[1].kind == "title"

    @property
    def is_block(self) -> bool:
        """A row that is one wide thing with no title: a chart."""
        first = self.elements[0]
        return first.kind != "title" and first.right - first.left > 400

    @property
    def left(self) -> float | None:
        """The title's left edge; a row that is only a control has none."""
        title = self.elements[1] if self.is_marked else self.elements[0]
        return title.left if title.kind == "title" else None

    @property
    def accessory(self) -> Element | None:
        last = self.elements[-1]
        return last if len(self.elements) > 1 and last.kind in ("info", "icon", "mark") else None

    @property
    def control(self) -> Element | None:
        rest = self.elements[:-1] if self.accessory else self.elements
        rest = rest[1:] if self.is_marked else rest
        rest = rest[1:] if self.left is not None else rest
        return rest[-1] if rest else None

    @property
    def offset(self) -> float | None:
        """How far the accessory's vertical center is below its control's."""
        if not self.accessory or not self.control or self.control.kind in ("text", "disabled"):
            return None
        return self.accessory.middle - self.control.middle

    @property
    def kind(self) -> str:
        """What the row holds, for comparing heights."""
        control = self.control.kind if self.control else "none"
        return f"{control}, {self.lines_under} under"


@dataclass
class Pane:
    name: str
    scale: float
    card_left: float = 0
    card_right: float = 0
    rows: list[Row] = field(default_factory=list)
    outside: list[tuple[float, float]] = field(default_factory=list)


def runs(flags: np.ndarray) -> list[tuple[int, int]]:
    """The [start, end) spans where `flags` is true."""
    edges = np.flatnonzero(np.diff(np.concatenate(([0], flags.astype(np.int8), [0]))))
    return list(zip(edges[::2].tolist(), edges[1::2].tolist()))


def most_common(colors: np.ndarray) -> np.ndarray:
    packed = (colors[:, 0] << 16) | (colors[:, 1] << 8) | colors[:, 2]
    value = Counter(packed.tolist()).most_common(1)[0][0]
    return np.array([(value >> 16) & 255, (value >> 8) & 255, value & 255])


def classify(element: Element) -> str:
    width = element.right - element.left
    if element.strength < FAINT:
        return "disabled"
    if 11 <= width <= 17 and 11 <= element.height <= 17:
        return "info" if element.density < 0.62 else "mark"
    if width > 60 and element.height >= 17 and element.density < 0.6:
        return "field"
    if 30 <= width <= 46 and 17 <= element.height <= 26 and element.density > 0.7:
        return "switch"
    if element.height >= 17 and element.density > 0.6:
        return "button"
    if width <= 22 and element.height >= 9 and element.density < 0.62:
        return "icon"
    return "text"


def merge(spans: list[tuple[int, int]], gap: float) -> list[tuple[int, int]]:
    merged: list[tuple[int, int]] = []
    for start, end in spans:
        if merged and start - merged[-1][1] <= gap:
            merged[-1] = (merged[-1][0], end)
        else:
            merged.append((start, end))
    return merged


def measure(path: Path) -> tuple[Pane, Image.Image]:
    image = Image.open(path).convert("RGB")
    pixels = np.asarray(image).astype(np.int32)
    height, width, _ = pixels.shape
    scale = width / PANE_POINTS
    pane = Pane(name=path.stem.removeprefix("pane-"), scale=scale)

    background = most_common(pixels[:, : int(6 * scale)].reshape(-1, 3))
    is_background = (np.abs(pixels - background).max(axis=2) <= SAME)
    card_color = most_common(pixels[~is_background].reshape(-1, 3))
    is_card = (np.abs(pixels - card_color).max(axis=2) <= SAME)
    outside_content = ~is_background & ~is_card
    delta = np.abs(pixels - card_color).max(axis=2)

    # A card's body: scanlines whose pixels a little inside both edges are card-colored.
    columns = np.flatnonzero(is_card.sum(axis=0) > 0.1 * is_card.sum(axis=0).max())
    card_left, card_right = int(columns.min()), int(columns.max()) + 1
    pane.card_left, pane.card_right = card_left / scale, card_right / scale
    # Inside a card anything off the card's color is content, a white switch knob included.
    # Rows are read inside the card's padding, clear of its rounded corners.
    inner_left, inner_right = card_left + int(6 * scale), card_right - int(6 * scale)
    probe = int(3 * scale)
    in_card = is_card[:, card_left + probe] & is_card[:, card_right - 1 - probe]
    # Content can reach neither probe column, so short gaps inside a card are rows of it.
    cards = merge(runs(in_card), gap=2 * scale)
    cards = [(top, bottom) for top, bottom in cards if bottom - top > 12 * scale]

    inner_width = inner_right - inner_left
    for index, (top, bottom) in enumerate(cards):
        body = ~is_card[top:bottom, inner_left:inner_right]
        # A separator: a line of content most of the card wide and at most 1.5 pt tall.
        separators = [
            span for span in runs(body.sum(axis=1) > 0.8 * inner_width) if span[1] - span[0] <= 1.5 * scale
        ]
        edges = [0] + [edge for span in separators for edge in span] + [bottom - top]
        for row_top, row_bottom in zip(edges[::2], edges[1::2]):
            contrast = delta[top + row_top: top + row_bottom, inner_left:inner_right]
            row = measure_row(body[row_top:row_bottom], contrast, index, top + row_top, inner_left, scale)
            if row:
                # A row runs from one separator's middle to the next; at a card's edge it is
                # measured as if a separator were there.
                first, last = row_top == 0, row_bottom == bottom - top
                row.height = (row_bottom - row_top) / scale + sum(
                    CARD_EDGE if at_edge else 0.5 for at_edge in (first, last)
                )
                pane.rows.append(row)

    # Headers and footers: text on the background between cards.
    outside = outside_content.copy()
    for top, bottom in cards:
        outside[top:bottom] = False
    for top, bottom in merge(runs(outside.any(axis=1)), gap=1 * scale):
        xs = np.flatnonzero(outside[top:bottom].any(axis=0))
        if len(xs) and bottom - top > 4 * scale:
            pane.outside.append(((top + bottom) / 2 / scale, xs.min() / scale))
    return pane, image


def measure_row(
    body: np.ndarray, contrast: np.ndarray, card: int, top: int, card_left: int, scale: float
) -> Row | None:
    if not body.any():
        return None
    width = body.shape[1]
    # Text lines, from the leading half: a trailing control is taller than its line.
    lines = merge(runs(body[:, : width // 2].any(axis=1)), gap=0.5 * scale)
    lines = [line for line in lines if line[1] - line[0] >= 5 * scale]
    if not lines:
        lines = merge(runs(body.any(axis=1)), gap=0.5 * scale)
    title = lines[0]
    reach = int(REACH * scale)
    band_top = max(0, title[0] - reach)
    band = body[band_top: title[1] + reach]
    strength = contrast[band_top: title[1] + reach]
    strict = body[title[0]: title[1]]
    elements = []
    for start, end in merge(runs(strict.any(axis=0)), gap=ELEMENT_GAP * scale):
        # A control taller than the title line: take its whole height, read from its solid
        # pixels where it has any, clear of its soft shadow.
        peak = int(strength[:, start:end].max())
        box = strength[:, start:end] > SOLID if peak > SOLID else band[:, start:end]
        rows = np.flatnonzero(box.any(axis=1))
        tall = merge(runs(box.any(axis=1)), gap=0)
        own = max(tall, key=lambda span: span[1] - span[0]) if tall else (0, 0)
        box = box[own[0]: own[1]]
        # Its edges are read from every pixel off the card's color, a faint bezel included.
        xs = np.flatnonzero(band[own[0]: own[1], start:end].any(axis=0))
        if not len(xs) or not len(rows):
            continue
        element = Element(
            left=(card_left + start + xs.min()) / scale,
            right=(card_left + start + xs.max() + 1) / scale,
            height=(own[1] - own[0]) / scale,
            density=float(box[:, xs.min(): xs.max() + 1].mean()),
            middle=(top + band_top + (own[0] + own[1]) / 2) / scale,
            strength=peak,
        )
        element.kind = classify(element)
        elements.append(element)
    if not elements:
        return None
    first = elements[0]
    if len(elements) > 1 and first.right - first.left <= 20 and first.height <= 20 and first.kind != "switch":
        first.kind = "mark"
        elements[1].kind = "title" if elements[1].kind == "text" else elements[1].kind
    first.kind = "title" if first.kind == "text" else first.kind
    under = lines[1:]
    widest = 0.0
    for line in under:
        xs = np.flatnonzero(body[line[0]: line[1]].any(axis=0))
        widest = max(widest, (xs.max() + 1 - xs.min()) / scale) if len(xs) else widest
    return Row(
        card=card,
        top=top / scale,
        height=0,
        title_center=(top + (title[0] + title[1]) / 2) / scale,
        elements=elements,
        lines_under=len(under),
        widest_under=widest,
    )


def line_of(values: list[float]) -> float | None:
    """The value most rows share, to half a point."""
    if not values:
        return None
    return Counter(round(value * 2) / 2 for value in values).most_common(1)[0][0]


def lines_of(pane: Pane) -> dict[str, float | None]:
    # The card's title edge is the leftmost any title starts; a row with a mark's column and
    # nothing drawn in it starts its title past the column all the same.
    lefts = [round(row.elements[0].left * 2) / 2 for row in pane.rows if row.left is not None]
    plain = min(lefts) if lefts else None
    return {
        # A title starts on the card's edge, or one mark's width past it.
        "lefts": [] if plain is None else [plain, plain + MARK_INDENT],
        "left": plain,
        "control": line_of([row.control.right for row in pane.rows if row.control]),
        "accessory": line_of(
            [(row.accessory.left + row.accessory.right) / 2 for row in pane.rows if row.accessory]
        ),
    }


def heights_of(pane: Pane) -> dict[int, float]:
    """The height most rows share, by the number of lines under the title."""
    heights: dict[int, float] = {}
    for lines in {row.lines_under for row in pane.rows}:
        values = [
            row.height
            for row in pane.rows
            if row.lines_under == lines and row.height < BLOCK_HEIGHT and not row.is_block
        ]
        if values:
            heights[lines] = line_of(values)
    return heights


def faults_of(row: Row, lines: dict[str, float | None], heights: dict[int, float]) -> list[str]:
    """The kit's rules this row breaks."""
    faults = []
    if row.is_block:
        return faults
    if row.left is not None and not any(abs(row.left - left) <= OFF_LINE + 1 for left in lines["lefts"]):
        faults.append("title edge")
    control = row.control
    # A spinner's spokes stop short of its frame, and a disabled control is too faint to read.
    is_spinner = control is not None and control.kind == "text" and control.right - control.left < 20
    if control and control.kind != "disabled" and not is_spinner and lines["control"] is not None:
        if abs(control.right - lines["control"]) > OFF_LINE:
            faults.append("control edge")
    if row.accessory and lines["accessory"] is not None:
        if abs((row.accessory.left + row.accessory.right) / 2 - lines["accessory"]) > OFF_LINE:
            faults.append("accessory column")
    if row.offset is not None and abs(row.offset) > OFF_CENTER:
        faults.append("accessory center")
    if row.lines_under > 1:
        faults.append("wraps")
    expected = heights.get(row.lines_under)
    if expected is not None and row.height < BLOCK_HEIGHT and abs(row.height - expected) > OFF_HEIGHT:
        faults.append("height")
    return faults


def annotate(pane: Pane, image: Image.Image, lines: dict[str, float | None], out: Path) -> None:
    draw = ImageDraw.Draw(image, "RGBA")
    scale = pane.scale
    colors = {"left": (0, 110, 255, 200), "control": (255, 40, 40, 200), "accessory": (0, 160, 70, 200)}
    for name, x in lines.items():
        if name in colors and x is not None:
            draw.line([(x * scale, 0), (x * scale, image.height)], fill=colors[name], width=1)
    for y, x in pane.outside:
        draw.line([(x * scale, (y - 5) * scale), (x * scale, (y + 5) * scale)], fill=(160, 0, 200, 255), width=2)
    for row in pane.rows:
        y = row.title_center * scale
        draw.line([(pane.card_left * scale, y), (pane.card_right * scale, y)], fill=(0, 0, 0, 40), width=1)
        marks = [("left", row.left)] if row.left is not None else []
        if row.offset is not None and abs(row.offset) > OFF_CENTER:
            x = (row.accessory.left + row.accessory.right) / 2 * scale
            draw.ellipse([(x - 9 * scale, y - 9 * scale), (x + 9 * scale, y + 9 * scale)], outline=(255, 0, 200, 255), width=2)
        if row.control:
            marks.append(("control", row.control.right))
        if row.accessory:
            marks.append(("accessory", (row.accessory.left + row.accessory.right) / 2))
        for name, x in marks:
            off = lines[name] is not None and abs(x - lines[name]) > OFF_LINE
            if name == "left":
                off = not any(abs(x - left) <= OFF_LINE + 1 for left in lines["lefts"])
            fill = (255, 0, 200, 255) if off else colors[name]
            draw.line([(x * scale, y - 7 * scale), (x * scale, y + 7 * scale)], fill=fill, width=3 if off else 2)
        if row.lines_under > 1:
            edge = row.elements[0].left * scale
            draw.rectangle(
                [(edge - 6, y + 8 * scale), (edge - 3, y + (8 + 14 * row.lines_under) * scale)],
                fill=(255, 0, 200, 255),
            )
    image.save(out)


def table(pane: Pane, lines: dict[str, float | None]) -> str:
    def cell(value: float | None, line: float | None) -> str:
        if value is None:
            return "–"
        mark = " **off**" if line is not None and abs(value - line) > OFF_LINE else ""
        return f"{value:.1f}{mark}"

    out = [
        f"## {pane.name}",
        "",
        f"Card {pane.card_left:.1f} to {pane.card_right:.1f} pt. Lines: title left {lines['left']}, "
        f"control right {lines['control']}, accessory center {lines['accessory']}.",
        "",
        "| card | row top | height | title left | control (kind, right) | accessory center | "
        "accessory below control | lines under | widest under | breaks |",
        "|---|---|---|---|---|---|---|---|---|---|",
    ]
    heights = heights_of(pane)
    for row in pane.rows:
        control = row.control
        accessory = row.accessory
        out.append(
            f"| {row.card} | {row.top:.0f} | {row.height:.1f} | {cell(row.left, None)} | "
            + (f"{control.kind} {cell(control.right, lines['control'])}" if control else "–")
            + " | "
            + (cell((accessory.left + accessory.right) / 2, lines["accessory"]) if accessory else "–")
            + " | "
            + (f"{row.offset:+.2f}" if row.offset is not None else "–")
            + f" | {row.lines_under} | {row.widest_under:.0f} | {', '.join(faults_of(row, lines, heights))} |"
        )
    out += ["", "Row heights: " + ", ".join(f"{h} pt with {n} under" for n, h in sorted(heights.items())) + "."]
    lefts = sorted({round(x * 2) / 2 for _, x in pane.outside})
    out += ["", f"Header and footer text starts at: {', '.join(f'{x:.1f}' for x in lefts) or '–'} pt.", ""]
    return "\n".join(out)


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    report = ["# Settings row measurements", "", "Points from the pane's left edge; the pane is 610 pt wide.", ""]
    summary = [
        "| pane | title left | control right | accessory center | row heights (0, 1 under) | "
        "accessory below button, worst | rows | breaking a rule |",
        "|---|---|---|---|---|---|---|---|",
    ]
    sections = []
    broken = []
    for path in map(Path, sys.argv[2:]):
        pane, image = measure(path)
        lines = lines_of(pane)
        heights = heights_of(pane)
        annotate(pane, image, lines, out / f"{pane.name}-guides.png")
        faults = [(row, faults_of(row, lines, heights)) for row in pane.rows]
        broken += [f"{pane.name}: row at {row.top:.0f} pt: {', '.join(found)}" for row, found in faults if found]
        offsets = [row.offset for row in pane.rows if row.offset is not None and row.control.kind == "button"]
        worst = max(offsets, key=abs) if offsets else None
        summary.append(
            f"| {pane.name} | {lines['left']} | {lines['control']} | {lines['accessory']} | "
            f"{heights.get(0, '–')}, {heights.get(1, '–')} | "
            + (f"{worst:+.2f}" if worst is not None else "–")
            + f" | {len(pane.rows)} | {sum(1 for _, found in faults if found)} |"
        )
        sections.append(table(pane, lines))
    (out / "measurements.md").write_text("\n".join(report + summary + [""] + sections))
    print("\n".join(summary))
    if broken:
        print("\n".join(broken), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
