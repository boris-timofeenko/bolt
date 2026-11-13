# Три варианта иконки Bolt в стиле ризографа, как картинка promo/bolt-*.png:
# жёлтая молния, синие тестовые фото, зелёный на перекрытии, бумага, сбитая приводка, зерно.
# Плитка и поля как у нынешней иконки (scripts/make-icon.swift): 824 px на холсте 1024, скругление 185.
# Для 16 и 32 px отдельная простая отрисовка: сплошные формы без растра и зерна.
# Запуск: python3 promo/src/icon.py   → promo/icon/<вариант>-1024.png, <вариант>-flat-1024.png, preview.png
import os, subprocess, tempfile
from PIL import Image, ImageDraw, ImageFilter, ImageChops, ImageFont
from make import BOLT, BLUE, YELLOW, crop, halftone

OUT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "icon"))
os.makedirs(OUT, exist_ok=True)
S = 1024
TILE = (100, 100, 924, 924)
PAPER = (244, 240, 231)

def bolt(scale=1.0, dx=0, dy=0):
    """Молния из иконки в системе 1024 с осью Y вниз, масштаб от центра плитки."""
    return [(512 + (x - 512) * scale + dx, 512 + ((1024 - y) - 512) * scale + dy) for x, y in BOLT]

def photo_density(i, w, h, angle, tone):
    """Тестовое фото как плотность синей краски: тёмные полоски печатаются гуще.
    tone < 1 — светлее, чтобы молния поверх оставалась жёлтой, а не уходила в тёмно-зелёный."""
    fr = crop(i, w, h, zoom=6).convert("L").point(lambda v: int((255 - v) * tone))
    m = Image.new("L", (w, h), 255)
    return fr.rotate(angle, expand=True, resample=Image.BICUBIC), m.rotate(angle, expand=True)

def paste_center(layer, im, mask, cx, cy, flat, tint):
    x, y = int(cx - im.width / 2), int(cy - im.height / 2)
    layer.paste(tint if flat else im, (x, y), mask)

# Каждый вариант отдаёт две формы: синюю и жёлтую, как плотность 0..255.
def stack(flat):
    blue = Image.new("L", (S, S), 0)
    for k, (ang, cx, cy) in enumerate([(-14, 470, 560), (-2, 512, 530), (11, 556, 500)]):
        im, m = photo_density(3 + k * 4, 400, 300, ang, 0.8)
        paste_center(blue, im, m, cx, cy, flat, 150)
        if flat:  # бумажный просвет между фото, чтобы в 32 px не слиплось в пятно
            edge = m.filter(ImageFilter.FIND_EDGES).filter(ImageFilter.MaxFilter(13))
            blue.paste(0, (int(cx - m.width / 2), int(cy - m.height / 2)), edge)
            blue.paste(150, (int(cx - m.width / 2), int(cy - m.height / 2)),
                       m.filter(ImageFilter.MinFilter(13)))
    yellow = Image.new("L", (S, S), 0)
    ImageDraw.Draw(yellow).polygon(bolt(1.05, 0, -8), fill=255)
    return blue, yellow, bolt(1.05, 22, 14)

def window(flat):
    blue = Image.new("L", (S, S), 0)
    im, _ = photo_density(10, 584, 584, 0, 0.6)
    m = Image.new("L", (584, 584), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, 583, 583), 28, fill=255)
    blue.paste(120 if flat else im, (220, 220), m)  # в простой отрисовке фото — светлый тон синего
    yellow = Image.new("L", (S, S), 0)
    ImageDraw.Draw(yellow).polygon(bolt(1.32), fill=255)
    return blue, yellow, bolt(1.32, 24, 16)

def outline(flat):
    blue = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(blue)
    d.rounded_rectangle((220, 220, 804, 804), 28, outline=255, width=34)
    # Синяя тень молнии: та же форма, сдвинутая вниз и вправо, как при сбитой приводке.
    shadow = Image.new("L", (S, S), 0)
    ImageDraw.Draw(shadow).polygon(bolt(1.0, 34, 26), fill=255 if flat else 200)
    blue = ImageChops.lighter(blue, shadow)
    yellow = Image.new("L", (S, S), 0)
    ImageDraw.Draw(yellow).polygon(bolt(1.0, -10, -8), fill=255)
    return blue, yellow, None

def print_ink(paper, mask, color, grain):
    layer = Image.new("RGB", paper.size, color)
    if grain:
        noise = Image.effect_noise(paper.size, 40).point(lambda v: 255 if v > 50 else 170)
        mask = ImageChops.multiply(mask, noise)
    return Image.composite(ImageChops.multiply(paper, layer), paper, mask)

def render(variant, flat):
    blue, yellow, ghost = variant(flat)
    paper = Image.new("RGB", (S, S), PAPER)
    if flat:
        im = print_ink(paper, yellow, YELLOW, False)
        im = print_ink(im, blue, BLUE, False)
    else:
        # Синяя форма растром, жёлтая сплошняком плюс растровая жёлтая тень, синяя сдвинута.
        blue_mask = halftone(blue, 17, 15)
        if variant is outline:  # рамка остаётся сплошной линией, растр только в тени
            frame = Image.new("L", (S, S), 0)
            ImageDraw.Draw(frame).rounded_rectangle((220, 220, 804, 804), 28, outline=255, width=34)
            blue_mask = ImageChops.lighter(halftone(ImageChops.subtract(blue, frame), 17, 15), frame)
        y = yellow
        if ghost:
            g = Image.new("L", (S, S), 0)
            ImageDraw.Draw(g).polygon(ghost, fill=140)
            y = ImageChops.lighter(yellow, halftone(g, 12, 75))
        im = print_ink(paper, y, YELLOW, True)
        im = print_ink(im, blue_mask.transform((S, S), Image.AFFINE, (1, 0, -7, 0, 1, 5)), BLUE, True)
    # Плитка и тень как у нынешней иконки.
    tile = Image.new("L", (S, S), 0)
    ImageDraw.Draw(tile).rounded_rectangle(TILE, 185, fill=255)
    out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sh.putalpha(tile.point(lambda v: int(v * 0.35)).filter(ImageFilter.GaussianBlur(24)))
    out.alpha_composite(sh, (0, 10))
    im = im.convert("RGBA"); im.putalpha(tile)
    out.alpha_composite(im)
    return out

def current_icon():
    tmp = tempfile.mkdtemp()
    subprocess.run(["iconutil", "-c", "iconset", "App/AppIcon.icns", "-o", f"{tmp}/a.iconset"],
                   check=True, cwd=os.path.join(OUT, "..", ".."))
    # Нынешняя иконка в своих настоящих размерах из icns, а не уменьшенная из 1024.
    files = {256: "icon_256x256", 128: "icon_128x128", 64: "icon_32x32@2x", 32: "icon_32x32", 16: "icon_16x16"}
    return {px: Image.open(f"{tmp}/a.iconset/{n}.png").convert("RGBA") for px, n in files.items()}

def sized(full, flat, px):
    """С 64 px и больше — растр, в 32 и 16 — простая отрисовка."""
    return (flat if px <= 32 else full).resize((px, px), Image.LANCZOS)

VARIANTS = {"stack": stack, "window": window, "outline": outline}
rows = [("нынешняя", current_icon(), None)]
for name, fn in VARIANTS.items():
    full, flat = render(fn, False), render(fn, True)
    full.save(f"{OUT}/{name}-1024.png")
    flat.save(f"{OUT}/{name}-flat-1024.png")
    rows.append((name, full, flat))
    print(f"{OUT}/{name}-1024.png")

SIZES = [256, 128, 64, 32, 16]
cell, label_w = 280, 170
half = label_w + cell * len(SIZES)
sheet = Image.new("RGB", (half * 2, cell * len(rows) + 50), (0, 0, 0))
d = ImageDraw.Draw(sheet)
f = ImageFont.truetype("/System/Library/Fonts/Supplemental/PTSans.ttc", 28, index=7)
for side, (bg, fg) in enumerate([((246, 246, 246), (30, 30, 30)), ((30, 30, 32), (230, 230, 230))]):
    ox = side * half
    d.rectangle((ox, 0, ox + half, sheet.height), fill=bg)
    for c, px in enumerate(SIZES):
        d.text((ox + label_w + c * cell + 10, 10), f"{px} px", font=f, fill=fg)
    for r, (name, full, flat) in enumerate(rows):
        y = 50 + r * cell
        d.text((ox + 14, y + cell // 2 - 16), name, font=f, fill=fg)
        for c, px in enumerate(SIZES):
            im = full[px] if flat is None else sized(full, flat, px)
            sheet.paste(im, (ox + label_w + c * cell + 10, y + (cell - px) // 2), im)
sheet.save(f"{OUT}/preview.png")
print(f"{OUT}/preview.png")
