"""Generates the per-player marker sprites (assets/sprites/player_<id>.png).

Run manually whenever the palette changes: `python _generate.py`. Not
loaded by the mod at runtime - the mod reads the .png files this writes,
same as any other sprite asset.

v1 marker, not a real character sprite: a filled circle with a black
outline and a small highlight, one flat color per player id. Simple on
purpose - trueColor sprites don't need to match Gen1's 6-frame walker
layout at all (frames=1 always draws the same image regardless of
facing/movement, SpriteRenderer clamps any requested frame index to
what's actually on the sheet), so there's no walk-cycle art to draw for
a first pass. A real animated character sprite is future work once
having ANY visible marker is confirmed working.
"""

from PIL import Image, ImageDraw

SIZE = 16

# id -> (name, RGB). id 0 is the host; 1-9 are joiners, matching
# nextPeerId in main.lua. Chosen for mutual contrast at a glance, not
# for any deeper meaning.
COLORS = {
    0: ("ROUGE", (216, 30, 30)),
    1: ("BLEU", (40, 90, 220)),
    2: ("VERT", (40, 170, 60)),
    3: ("JAUNE", (230, 200, 20)),
    4: ("MAUVE", (150, 60, 200)),
    5: ("ORANGE", (230, 120, 20)),
    6: ("CYAN", (30, 190, 200)),
    7: ("ROSE", (230, 100, 170)),
    8: ("BRUN", (140, 90, 50)),
    9: ("GRIS", (140, 140, 150)),
}


def draw_marker(color):
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # body: filled circle, black outline, small white highlight so it
    # doesn't read as a flat blob against similarly-colored terrain
    d.ellipse((2, 3, 13, 14), fill=color, outline=(20, 20, 20), width=1)
    d.ellipse((4, 5, 6, 7), fill=(255, 255, 255, 180))
    return img


if __name__ == "__main__":
    names = []
    for pid, (name, color) in COLORS.items():
        img = draw_marker(color)
        path = f"player_{pid}.png"
        img.save(path)
        names.append(f"{pid}={name}")
    print("wrote:", ", ".join(f"player_{pid}.png" for pid in COLORS))
    print("colors:", ", ".join(names))
