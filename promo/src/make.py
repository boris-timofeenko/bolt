# Рисует promo/bolt-ru.png и promo/bolt-en.png, 1600x900, в стиле ризографа: жёлтая молния
# из иконки и синяя стопка синтетических тестовых фото Bolt
# (~/bolt-perf-photos/synth200: HEIC 4032x3024, цветное поле в мелкую полоску).
# Запуск: python3 promo/src/make.py
import math, os, subprocess, tempfile
from PIL import Image, ImageDraw, ImageFont, ImageFilter, ImageChops

SRC = os.path.expanduser("~/bolt-perf-photos/synth200")
OUT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
W, H = 1600, 900
TEXT = {
    "en": ("Bolt", "blazingly fast photo viewer for macOS"),
    "ru": ("Bolt", "молниеносный просмотрщик фото для macOS"),
}
# Молния из scripts/make-icon.swift, координаты в системе 1024 с осью Y вверх.
BOLT = [(580, 800), (370, 500), (500, 500), (430, 224), (660, 560), (526, 560), (600, 800)]

FONTS = "/System/Library/Fonts"
def font(name, size, index=0):
    return ImageFont.truetype(f"{FONTS}/{name}", size, index=index)

_tmp = tempfile.mkdtemp()
_cache = {}
def photo(i):
    """Тестовое фото целиком, 4032x3024."""
    i = (i - 1) % 200 + 1
    if i not in _cache:
        p = os.path.join(_tmp, f"{i}.png")
        subprocess.run(["sips", "-s", "format", "png", f"{SRC}/IMG_{i:04d}.HEIC", "--out", p],
                       check=True, capture_output=True)
        _cache[i] = Image.open(p).convert("RGB")
    return _cache[i]

def crop(i, w, h, zoom=2, dx=0):
    """Кусок фото 1:1 из центра, увеличенный без сглаживания, чтобы полоска была видна."""
    im = photo(i)
    cw, ch = math.ceil(w / zoom), math.ceil(h / zoom)
    x, y = im.width // 2 - cw // 2 + dx, im.height // 2 - ch // 2
    return im.crop((x, y, x + cw, y + ch)).resize((cw * zoom, ch * zoom), Image.NEAREST).crop((0, 0, w, h))

def bolt_points(x, y, height):
    """Молния высотой height, левый верхний угол её рамки в (x, y)."""
    k = height / (800 - 224)
    return [(x + (px - 370) * k, y + (800 - py) * k) for px, py in BOLT]

# Ризограф: две краски, жёлтая и синяя, растр точками и сбитая приводка.
YELLOW, BLUE = (255, 213, 0), (0, 92, 170)
def halftone(density, pitch, angle):
    """Растр: на каждом узле повёрнутой сетки точка, площадь которой равна плотности краски."""
    out = Image.new("L", density.size, 0)
    d = ImageDraw.Draw(out)
    ca, sa = math.cos(math.radians(angle)), math.sin(math.radians(angle))
    R = int(math.hypot(*density.size) / pitch) + 2
    px = density.load()
    for a in range(-R, R):
        for b in range(-R, R):
            x = a * pitch * ca - b * pitch * sa
            y = a * pitch * sa + b * pitch * ca
            if 0 <= x < density.width and 0 <= y < density.height:
                v = px[int(x), int(y)] / 255
                r = pitch * 0.62 * math.sqrt(v)
                if r > 0.6:
                    d.ellipse((x - r, y - r, x + r, y + r), fill=255)
    return out

def ink(paper, mask, color):
    """Краска ложится поверх бумаги и предыдущей краски (умножение), с пропусками зерна."""
    layer = Image.new("RGB", paper.size, color)
    noise = Image.effect_noise(paper.size, 40).point(lambda v: 255 if v > 50 else 170)
    mask = ImageChops.multiply(mask, noise)
    inked = ImageChops.multiply(paper, layer)
    return Image.composite(inked, paper, mask)

def riso(lang):
    title, line = TEXT[lang]
    paper = Image.new("RGB", (W, H), (244, 240, 231))
    # Синяя форма: три фото веером, тон берём из самих фото, полоска остаётся в растре.
    blue = Image.new("L", (W, H), 0)
    for j, (ang, ox, oy) in enumerate([(-10, 1200, 470), (3, 1240, 430), (13, 1290, 380)]):
        fr = crop(3 + j * 4, 280, 210, zoom=5).convert("L").point(lambda v: int((255 - v) * 0.9))
        fr = fr.rotate(ang, expand=True, resample=Image.BICUBIC, fillcolor=0)
        m = Image.new("L", (280, 210), 255).rotate(ang, expand=True, fillcolor=0)
        blue.paste(fr, (ox, oy), m)
    blue_dots = halftone(blue, 7, 15)
    text = Image.new("L", (W, H), 0)
    t = ImageDraw.Draw(text)
    t.text((80, 170), title, font=font("Supplemental/PTSans.ttc", 260, 2), fill=255)
    t.text((88, 440), line, font=font("Supplemental/PTSans.ttc", 52, 7), fill=255)
    blue_mask = ImageChops.lighter(blue_dots, text)
    # Жёлтая форма: большая молния сплошняком, под ней растровая тень.
    yellow = Image.new("L", (W, H), 0)
    y = ImageDraw.Draw(yellow)
    y.polygon(bolt_points(1230, 90, 700), fill=150)
    yellow_dots = halftone(yellow.filter(ImageFilter.GaussianBlur(3)), 8, 75)
    y2 = Image.new("L", (W, H), 0)
    ImageDraw.Draw(y2).polygon(bolt_points(1200, 70, 700), fill=255)
    yellow_mask = ImageChops.lighter(yellow_dots, y2)
    im = ink(paper, yellow_mask, YELLOW)
    im = ink(im, blue_mask.transform((W, H), Image.AFFINE, (1, 0, -5, 0, 1, 3)), BLUE)
    return im


if __name__ == "__main__":
    for lang in ("ru", "en"):
        p = f"{OUT}/bolt-{lang}.png"
        riso(lang).save(p)
        print(p)
