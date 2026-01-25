#!/usr/bin/env python3
"""
Generate Disk Inventory Y app icon - recursive treemap view
Green, orange, and blue color scheme
"""

from PIL import Image, ImageDraw


def draw_cushion_rect(x1, y1, x2, y2, base_color, img):
    """Draw a rectangle with cushion shading (lighter center, darker edges)."""
    width = x2 - x1
    height = y2 - y1

    if width <= 2 or height <= 2:
        return

    cx = (x1 + x2) / 2
    cy = (y1 + y2) / 2

    for py in range(int(y1), int(y2)):
        for px in range(int(x1), int(x2)):
            dx = abs(px - cx) / (width / 2)
            dy = abs(py - cy) / (height / 2)
            edge_dist = max(0, min(1, (1 - dx) * (1 - dy)))
            brightness = 0.55 + 0.45 * (edge_dist ** 0.6)

            r = min(255, int(base_color[0] * brightness))
            g = min(255, int(base_color[1] * brightness))
            b = min(255, int(base_color[2] * brightness))

            img.putpixel((int(px), int(py)), (r, g, b, 255))


def recursive_treemap(img, x1, y1, x2, y2, colors, depth, gap, color_idx=0):
    """Recursively divide space - each block takes ~half, rest subdivides."""
    width = x2 - x1
    height = y2 - y1

    if width < 8 or height < 8 or depth <= 0:
        return

    color = colors[color_idx % len(colors)]

    if width > height:
        # Split horizontally - main block on left
        split = x1 + width * 0.5
        draw_cushion_rect(x1, y1, split - gap, y2, color, img)
        # Recurse on right half
        recursive_treemap(img, split + gap, y1, x2, y2, colors, depth - 1, gap, color_idx + 1)
    else:
        # Split vertically - main block on top
        split = y1 + height * 0.5
        draw_cushion_rect(x1, y1, x2, split - gap, color, img)
        # Recurse on bottom half
        recursive_treemap(img, x1, split + gap, x2, y2, colors, depth - 1, gap, color_idx + 1)


def create_treemap_icon(size):
    """Create a recursive treemap icon with green, orange, blue."""
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    corner_radius = max(size // 5, 4)
    draw.rounded_rectangle([0, 0, size-1, size-1], radius=corner_radius, fill=(45, 50, 60))

    # Green, orange, blue
    green = (70, 190, 120)
    orange = (255, 120, 40)  # More orange, less yellow
    blue = (80, 140, 210)

    # 1st: orange, 2nd: blue, 3rd: green, then cycle
    colors = [orange, blue, green, orange, blue, green]

    pad = size * 0.06
    gap = max(1, size // 80)

    recursive_treemap(img, pad, pad, size - pad, size - pad, colors, depth=6, gap=gap)

    return img


if __name__ == '__main__':
    sizes = [16, 32, 64, 128, 256, 512, 1024]

    for size in sizes:
        img = create_treemap_icon(size)
        img.save(f'icon_{size}x{size}.png')
        print(f'Created icon_{size}x{size}.png')

    print('Done!')
