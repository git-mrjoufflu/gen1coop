"""Generates the per-player marker sprites (assets/sprites/player_<id>.png).

Run manually whenever the palette changes: `python generate_sprites.py`.
Not loaded by the mod at runtime - the mod reads the .png files this
writes, same as any other sprite asset.

v2: a simple top-down person silhouette (round head + body, tiny feet),
one flat color per player id, still not a real animated character
sprite. trueColor sprites don't need to match Gen1's 6-frame walker
layout at all (frames=1 always draws the same image regardless of
facing/movement, SpriteRenderer clamps any requested frame index to
what's actually on the sheet), so there's no walk-cycle art to draw for
this pass either - a real animated sprite is still future work, this
just reads as "a little person" instead of "a dot" at a glance.
"""

from PIL import Image, ImageDraw

SIZE = 16
OUTLINE = (20, 20, 20, 255)
SKIN = (250, 210, 160, 255)

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
    # feet: two small dark stubs, drawn first so the body overlaps them
    d.rectangle((5, 13, 6, 14), fill=OUTLINE)
    d.rectangle((9, 13, 10, 14), fill=OUTLINE)
    # body: the player's color, trapezoid-ish so it reads as a torso
    d.polygon([(4, 7), (11, 7), (12, 13), (3, 13)], fill=color, outline=OUTLINE)
    # head: skin tone circle, small enough to leave room for the body
    d.ellipse((4, 1, 11, 8), fill=SKIN, outline=OUTLINE)
    # eyes
    d.point((6, 4), fill=OUTLINE)
    d.point((9, 4), fill=OUTLINE)
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
