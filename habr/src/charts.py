# Рисует картинки к статье в том же ризографическом виде, что и обложка (promo/src/make.py):
# habr/chart.png, habr/chart-hold.png, habr/chart-open.png, habr/41ms.png, 1600 px в ширину,
# и те же картинки с английскими подписями: habr/chart.en.png и так далее.
# Две краски: Bolt жёлтый, остальные программы и весь текст синие. Растр точками везде значит
# «фото на экране, но ещё не чёткое» (кроме 41ms.png, там точки — ожидание срока WindowServer).
# Запуск: python3 habr/src/charts.py
import os, sys
from PIL import Image, ImageDraw, ImageChops, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "promo", "src")))
from make import halftone, ink, font, YELLOW, BLUE  # noqa: E402

OUT = os.path.normpath(os.path.join(HERE, ".."))

# Подписи на двух языках: один запуск пишет русские картинки (chart.png …) и английские (chart.en.png …).
TEXT = {
    "ru": {
        "suffix": "", "decimal": ",",
        "programs": ["Bolt", "ApolloOne", "XnView MP", "«Просмотр»", "Quick Look"],
        "flip": {"title": "От стрелки до чёткого кадра, мс",
                 "panels": ["раз в секунду", "раз в 400 мс", "раз в 150 мс"]},
        "hold": {"title": "Стрелка зажата на три секунды",
                 "rate": "фото в секунду", "release": "после отпускания до чёткого кадра, мс",
                 "key": ("чётко", "на экране, но ещё не чётко")},
        "open": {"title": "Открытие из Finder, мс",
                 "key": ("фото ещё нет", "на экране, но ещё не чётко")},
        "frame": {"kicker": "от нажатия стрелки до фото на экране",
                  "big": "41 мс", "aside": "из них 1,2 мс — Bolt",
                  "frame_labels": ["0", "16,7", "33,3", "50 мс"],
                  "frames_caption": "кадры экрана, 60 Гц",
                  "one": "всё одной транзакцией: 54 мс",
                  "two": "фото отдельной транзакцией: 41 мс",
                  "captions": ["1,2 мс — Bolt", "ждём срок WindowServer, ~8 мс", "WindowServer и экран, ~32 мс"]},
    },
    "en": {
        "suffix": ".en", "decimal": ".",
        "programs": ["Bolt", "ApolloOne", "XnView MP", "Preview", "Quick Look"],
        "flip": {"title": "Arrow key to sharp frame, ms",
                 "panels": ["once a second", "every 400 ms", "every 150 ms"]},
        "hold": {"title": "Arrow key held for three seconds",
                 "rate": "photos per second", "release": "release to sharp frame, ms",
                 "key": ("sharp", "on screen, not sharp yet")},
        "open": {"title": "Opening from Finder, ms",
                 "key": ("no photo yet", "on screen, not sharp yet")},
        "frame": {"kicker": "from arrow key press to photo on screen",
                  "big": "41 ms", "aside": "of which 1.2 ms is Bolt",
                  "frame_labels": ["0", "16.7", "33.3", "50 ms"],
                  "frames_caption": "display frames, 60 Hz",
                  "one": "all in one transaction: 54 ms",
                  "two": "photo in its own transaction: 41 ms",
                  "captions": ["1.2 ms: Bolt", "waiting for deadline, ~8 ms", "WindowServer and display, ~32 ms"]},
    },
}

DATA = {
    # Рис. 1: от стрелки до чёткого кадра, медианы в мс, порядок как в programs.
    "flip": {
        "max": 250, "ticks": [0, 100, 200],
        "panels": [
            [31, 87, 116, 140, 172],
            [26, 64, 107, 123, 167],
            [27, 64, 229, 156, 197],
        ],
    },
    # Рис. 2: стрелка зажата три секунды.
    "hold": {
        "rate": {"max": 12, "ticks": [0, 5, 10],
                 "values": [10.3, 6.2, 2.7, 6.7, 0.3],
                 # доля чётких среди показанных; None — вывода сделать нельзя, только контур
                 "sharp": [1.0, 1.0, 1.0, 0.06, None]},
        "release": {"max": 800, "ticks": [0, 400, 800], "values": [0, 137, 780, 407, None]},
    },
    # Рис. 3: открытие из Finder, медианы в мс: (фото появилось, фото чёткое).
    "open": {
        "max": 2500, "ticks": [0, 500, 1000, 1500, 2000, 2500],
        "values": [(291, 350), (2119, 2119), (674, 674), (2300, 8250), (237, 637)],
    },
    # Рис. 4: из чего складываются 41 мс, отрезки в мс от нажатия.
    "frame": {
        "max": 60, "frames": [0, 50 / 3, 100 / 3, 50],
        "one": [("yellow", 0, 6.2), ("blue", 6.2, 54.1)],
        "two": [("yellow", 0, 1.2), ("dots", 1.2, 9.2), ("blue", 9.2, 41.4)],
    },
}
T = TEXT["ru"]   # текущий язык, меняется в __main__

PAPER = (244, 240, 231)
W = 1600
M = 72
PT = "Supplemental/PTSans.ttc"
def bold(size):   # PT Sans Narrow Bold, как «Bolt» на обложке
    return font(PT, size, 2)
def plain(size):  # PT Sans Bold, как подпись на обложке
    return font(PT, size, 7)
F_TITLE, F_NAME, F_HEAD, F_SMALL = bold(56), bold(38), plain(32), plain(28)
SHIFT = (2, -1)   # сбитая приводка синей формы: вправо на 2, вверх на 1
TRAP = 3          # жёлтая плашка заходит под соседнюю синюю, чтобы сдвиг не открыл бумагу
PITCH = 8
DOT_DENSITY = 105  # плотность растра, 0..255

def num(v):
    return f"{v:g}".replace(".", T["decimal"])


class Sheet:
    """Лист с двумя формами: синей и жёлтой. Всё рисуется масками, краска ложится в render()."""
    def __init__(self, h):
        self.size = (W, h)
        self.plate = {"blue": Image.new("L", self.size, 0), "yellow": Image.new("L", self.size, 0)}
        self.text = Image.new("L", self.size, 0)
        self.thin = Image.new("L", self.size, 0)   # тонкие линии, которые уступают тексту и жёлтому
        self._dots = {}
        self.boxes = []   # рамки текста: тонкие линии их обходят

    def draw(self, plate):
        if plate in ("text", "thin"):
            return ImageDraw.Draw(getattr(self, plate))
        return ImageDraw.Draw(self.plate[plate])

    def rect(self, plate, x0, y0, x1, y1):
        if x1 > x0:
            self.draw(plate).rectangle((round(x0), round(y0), round(x1) - 1, round(y1) - 1), fill=255)

    def dots(self, plate, x0, y0, x1, y1, shape=None):
        """Растр в прямоугольнике (или в маске shape): «на экране, но не чётко»."""
        if plate not in self._dots:
            angle = 15 if plate == "blue" else 75
            self._dots[plate] = halftone(Image.new("L", self.size, DOT_DENSITY), PITCH, angle)
        if shape is None:
            if round(x1) <= round(x0):
                return
            shape = Image.new("L", self.size, 0)
            ImageDraw.Draw(shape).rectangle((round(x0), round(y0), round(x1) - 1, round(y1) - 1), fill=255)
        self.plate[plate] = ImageChops.lighter(self.plate[plate], ImageChops.multiply(self._dots[plate], shape))

    def line(self, pts, width=2, plate="blue"):
        self.draw(plate).line(pts, fill=255, width=width)

    def write(self, xy, s, f, anchor="la"):
        self.draw("text").text(xy, s, font=f, fill=255, anchor=anchor)
        box = self.draw("text").textbbox(xy, s, font=f, anchor=anchor)
        self.boxes.append(box)
        return box

    def render(self, name):
        w, h = self.size
        paper = Image.new("RGB", self.size, PAPER)
        im = ink(paper, self.plate["yellow"], YELLOW)
        keep_out = self.plate["yellow"].filter(ImageFilter.MaxFilter(9))
        kd = ImageDraw.Draw(keep_out)
        for x0, y0, x1, y1 in self.boxes:
            kd.rectangle((x0 - 10, y0 - 6, x1 + 10, y1 + 6), fill=255)
        thin = ImageChops.multiply(self.thin, ImageChops.invert(keep_out))
        blue = ImageChops.lighter(ImageChops.lighter(self.plate["blue"], self.text), thin)
        dx, dy = SHIFT
        blue = blue.transform(self.size, Image.AFFINE, (1, 0, -dx, 0, 1, -dy))
        im = ink(im, blue, BLUE)
        base, ext = os.path.splitext(name)
        p = os.path.join(OUT, base + T["suffix"] + ext)
        im.save(p)
        print(p)
        return im


def bar_color(i):
    return "yellow" if i == 0 else "blue"

def names_column(s, rows_y, x=M):
    for name, y in zip(T["programs"], rows_y):
        s.write((x, y), name, F_NAME, "lm")
    return max(s.draw("text").textlength(n, font=F_NAME) for n in T["programs"])

def axis(s, x0, x1, y, vmax, ticks, labels=None):
    s.line([(x0, y), (x1, y)])
    for i, t in enumerate(ticks):
        x = x0 + (x1 - x0) * t / vmax
        s.line([(x, y), (x, y + 10)])
        s.write((x, y + 16), labels[i] if labels else num(t), F_SMALL, "ma")

def key(s, y, x, solid_text, dotted_text):
    s.rect("blue", x, y, x + 60, y + 26)
    b = s.write((x + 74, y + 13), solid_text, F_SMALL, "lm")
    x2 = b[2] + 48
    s.dots("blue", x2, y, x2 + 60, y + 26)
    s.write((x2 + 74, y + 13), dotted_text, F_SMALL, "lm")


def flip():
    d, t = DATA["flip"], T["flip"]
    s = Sheet(900)
    s.write((M, M), t["title"], F_TITLE, "lt")
    row0, pitch, bh = 274, 110, 60
    rows = [row0 + i * pitch for i in range(5)]
    name_w = names_column(s, rows)
    left = M + name_w + 40
    gap = 84
    pw = (W - M - left - 2 * gap - 64) / 3   # 64: место под число после самой длинной полосы
    for k, (heading, vals) in enumerate(zip(t["panels"], d["panels"])):
        x0 = left + k * (pw + gap)
        s.write((x0, 206), heading, F_HEAD, "ls")
        for i, (v, y) in enumerate(zip(vals, rows)):
            x1 = x0 + pw * v / d["max"]
            s.rect(bar_color(i), x0, y - bh / 2, x1, y + bh / 2)
            s.write((x1 + 10, y), num(v), F_NAME, "lm")
        axis(s, x0, x0 + pw, rows[-1] + bh / 2 + 22, d["max"], d["ticks"])
    return s.render("chart.png")


def hold():
    d, t = DATA["hold"], T["hold"]
    s = Sheet(760)
    s.write((M, M), t["title"], F_TITLE, "lt")
    row0, pitch, bh = 238, 74, 46
    rows = [row0 + i * pitch for i in range(5)]
    name_w = names_column(s, rows)
    left = M + name_w + 40
    gap, tail = 110, 70
    pw_l = 470
    pw_r = W - M - tail - left - pw_l - gap
    axis_y = rows[-1] + bh / 2 + 18
    # Левая панель: фото в секунду, заливка по доле чётких.
    r = d["rate"]
    x0 = left
    s.write((x0, 186), t["rate"], F_HEAD, "ls")
    for i, (v, sharp, y) in enumerate(zip(r["values"], r["sharp"], rows)):
        x1 = x0 + pw_l * v / r["max"]
        y0, y1 = y - bh / 2, y + bh / 2
        if sharp is None:
            s.draw("blue").rectangle((round(x0), round(y0), round(x1) - 1, round(y1) - 1), outline=255, width=2)
        else:
            xs = x0 + (x1 - x0) * sharp
            s.rect(bar_color(i), x0, y0, xs, y1)
            s.dots("blue", xs, y0, x1, y1)
        s.write((x1 + 10, y), num(v), F_NAME, "lm")
    axis(s, x0, x0 + pw_l, axis_y, r["max"], r["ticks"])
    # Правая панель: после отпускания до чёткого кадра, всё точками.
    r = d["release"]
    x0 = left + pw_l + gap
    s.write((x0, 186), t["release"], F_HEAD, "ls")
    for v, y in zip(r["values"], rows):
        if v is None:
            s.write((x0 + 10, y), "—", F_NAME, "lm")
            continue
        x1 = x0 + pw_r * v / r["max"]
        s.dots("blue", x0, y - bh / 2, x1, y + bh / 2)
        s.write((x1 + 10, y), num(v), F_NAME, "lm")
    axis(s, x0, x0 + pw_r, axis_y, r["max"], r["ticks"])
    key(s, 668, left, *t["key"])
    return s.render("chart-hold.png")


def zigzag_right(x, y0, y1, teeth=4, depth=10):
    """Точки правого края-излома от (x, y0) до (x, y1): зубцы глубиной depth."""
    pts = []
    step = (y1 - y0) / (2 * teeth)
    for j in range(2 * teeth + 1):
        pts.append((x - (depth if j % 2 else 0), y0 + j * step))
    return pts

def opening():
    d, t = DATA["open"], T["open"]
    s = Sheet(760)
    s.write((M, M), t["title"], F_TITLE, "lt")
    row0, pitch, bh = 196, 80, 50
    rows = [row0 + i * pitch for i in range(5)]
    name_w = names_column(s, rows)
    x0 = M + name_w + 40
    pw = W - M - 120 - x0
    sx = lambda v: x0 + pw * v / d["max"]
    for i, ((seen, sharp), y) in enumerate(zip(d["values"], rows)):
        plate = bar_color(i)
        y0, y1 = y - bh / 2, y + bh / 2
        xa = sx(min(seen, d["max"]))
        s.rect(plate, x0, y0, xa + (TRAP if plate == "yellow" and sharp > seen else 0), y1)
        if sharp <= d["max"]:
            xb = sx(sharp)
            if sharp > seen:
                s.dots(plate, xa, y0, xb, y1)
            end = xb
        else:
            # Не влезает: точки до края шкалы, обрыв двумя зигзагами с просветом бумаги.
            xb = sx(d["max"])
            zig = zigzag_right(xb, y0, y1, teeth=3, depth=14)
            shape = Image.new("L", s.size, 0)
            ImageDraw.Draw(shape).polygon([(xa, y0)] + zig + [(xa, y1)], fill=255)
            s.dots(plate, 0, 0, 0, 0, shape=shape)
            s.line(zig, width=4, plate=plate)
            end = xb
        s.write((end + 12, y), num(sharp), F_NAME, "lm")
    axis(s, x0, x0 + pw, rows[-1] + bh / 2 + 20, d["max"], d["ticks"])
    key(s, 668, x0, *t["key"])
    return s.render("chart-open.png")


def frame():
    d, t = DATA["frame"], T["frame"]
    s = Sheet(900)
    s.write((M, 92), t["kicker"], F_HEAD, "ls")
    big = bold(170)
    b = s.write((M - 6, 262), t["big"], big, "ls")
    s.write((b[2] + 36, 262), t["aside"], bold(56), "ls")
    x0, x1 = M + 24, W - M - 24
    sx = lambda v: x0 + (x1 - x0) * v / d["max"]
    top_one, h_one = 410, 46
    top_two, h_two = 534, 110
    axis_y = 780
    # Кадры экрана: тонкие вертикали и подписи под осью.
    for ft in d["frames"]:
        s.line([(sx(ft), top_one - 12), (sx(ft), axis_y)], width=1, plate="thin")
    s.line([(x0, axis_y), (x1, axis_y)])
    for ft, lab in zip(d["frames"], t["frame_labels"]):
        s.write((sx(ft), axis_y + 16), lab, F_SMALL, "ma")
    s.write((x1, top_one - 22), t["frames_caption"], F_SMALL, "rs")

    def bar(label, parts, top, h):
        s.write((x0, top - 22), label, F_SMALL, "ls")
        for j, (kind, a, z) in enumerate(parts):
            xa, xz = sx(a), sx(z)
            if kind == "yellow":
                s.rect("yellow", xa, top, xz + (TRAP if j + 1 < len(parts) else 0), top + h)
            elif kind == "dots":
                s.dots("blue", xa, top, xz, top + h)
            else:
                s.rect("blue", xa, top, xz, top + h)
        return [(sx(a), sx(z)) for _, a, z in parts]

    bar(t["one"], d["one"], top_one, h_one)
    seg = bar(t["two"], d["two"], top_two, h_two)
    c_bolt, c_wait, c_ws = t["captions"]
    y1, y2 = top_two + h_two + 34, top_two + h_two + 74
    s.write((seg[1][0] + 4, y1), c_wait, F_SMALL, "lm")
    s.write((seg[2][1], y1), c_ws, F_SMALL, "rm")
    s.write((seg[0][0], y2), c_bolt, F_SMALL, "lm")
    return s.render("41ms.png")


if __name__ == "__main__":
    for lang in ("ru", "en"):
        T = TEXT[lang]
        for f in (flip, hold, opening, frame):
            f()
