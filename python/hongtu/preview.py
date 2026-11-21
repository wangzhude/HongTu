"""Limited SVG presentation of a complete KLayout layout; never changes it."""
import html
from .policy import MAX_PREVIEW_CHARS, MAX_PREVIEW_SHAPES

PALETTE = ("#377be8", "#dc5962", "#45a181", "#aa69d0", "#db9948", "#4ca5b9")


def make_preview(layout):
    cells = list(layout.top_cells())
    if not cells:
        return "", False
    top = cells[0]
    box = top.bbox()
    if box.empty():
        return "", False
    pad = max(box.width(), box.height(), 1) * 0.045
    width = max(box.width() + 2 * pad, 1)
    height = max(box.height() + 2 * pad, 1)
    start = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{box.left-pad:g} '
             f'{box.bottom-pad:g} {width:g} {height:g}" width="960" height="600">'
             f'<rect x="{box.left-pad:g}" y="{box.bottom-pad:g}" width="{width:g}" '
             f'height="{height:g}" fill="white"/>')
    pieces = [start]
    seen = 0
    truncated = len(cells) > 1
    chars = len(start)
    for color_index, layer in enumerate(layout.layer_indexes()):
        color = PALETTE[color_index % len(PALETTE)]
        iterator = top.begin_shapes_rec(layer)
        while not iterator.at_end():
            if seen >= MAX_PREVIEW_SHAPES or chars >= MAX_PREVIEW_CHARS:
                truncated = True
                break
            shape = iterator.shape()
            trans = iterator.trans()
            item = ""
            if shape.is_text():
                text = shape.text.transformed(trans)
                size = max(width / 75, 1)
                item = (f'<text x="{text.x}" y="{text.y}" font-size="{size:g}" '
                        f'fill="{color}">{html.escape(text.string[:120])}</text>')
            elif shape.is_box() or shape.is_polygon() or shape.is_path():
                polygon = shape.polygon.transformed(trans)
                rings = [list(polygon.each_point_hull())]
                rings.extend(list(polygon.each_point_hole(i)) for i in range(polygon.holes()))
                commands = []
                for ring in rings:
                    if ring:
                        commands.append("M" + " L".join(f"{p.x},{p.y}" for p in ring) + " Z")
                d = " ".join(commands)
                item = (f'<path d="{d}" fill="{color}" fill-opacity="0.27" '
                        f'stroke="{color}" stroke-width="1" vector-effect="non-scaling-stroke" '
                        'fill-rule="evenodd"/>')
            if chars + len(item) > MAX_PREVIEW_CHARS:
                truncated = True
                break
            pieces.append(item)
            chars += len(item)
            seen += 1
            iterator.next()
        if truncated and (seen >= MAX_PREVIEW_SHAPES or chars >= MAX_PREVIEW_CHARS):
            break
    pieces.append("</svg>")
    return "".join(pieces), truncated
