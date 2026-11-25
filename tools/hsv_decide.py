"""Эталонная HSV-модель детекции включений двух ламп.

Правила те же, что потом лягут в Dart (`lib/src/detection/hsv_reference.dart`):

  признак   = доля пикселей ROI, прошедших HSV-отбор: `cool` (ярко, почти без
              насыщения) для белой лампы, `warm` (оттенок вокруг нуля,
              насыщенно) для красной;
  отсчёт    = 20-й процентиль окна последних N кадров того же признака;
  порог     = max(minRise, k·σ), ограничен снизу abs-минимумом, сверху —
              maxLevel и половиной собственного размаха;
  вето      = подъём СВОЕГО обязан как минимум в GATE раз перекрыть ЧУЖОЙ.
              Чужой бывает двух родов, и это РАЗНЫЕ правила (см. GATE_MODE):
              `same-zone` — чужой цвет в той же зоне (красная зона выбелена
              белой лампой), `cross-zone` — подъём чужого канала в чужой зоне.
              Оба сняли ложные красные включения в 190707 и 190736; между собой
              расходятся по числам, поэтому перебираются оба;
  пересвет  = зона упёрлась в потолок сенсора, СВОЙ признак почти единица, а
              чужой тоже заметен -> цвет не различим, состояние не меняется.

Запуск:  python tools/hsv_decide.py                       — по всем видео
         python tools/hsv_decide.py <video>              — по одному
         python tools/hsv_decide.py sweep [mode] 1.0 1.5 — перебор вето
         python tools/hsv_decide.py truth [gate] [mem]   — сверка с разметкой
         python tools/hsv_decide.py fit                  — подбор gate × mem
         python tools/hsv_decide.py ablate [gate]         — разрез трёх правок
                                                          по разметке
         python tools/hsv_decide.py cmp                  — яркость против цвета
                                                          по одной разметке
         python tools/hsv_decide.py events [rise] [new|штамп...]  — эпизоды без
                                                                    автомата
         python tools/hsv_decide.py amb [rise] [new|штамп...] — эпизоды против
                                                                    всего кадра
         python tools/hsv_decide.py oracle [gate] [new]  — что переключали: 
                                                          позиция против цвета
         python tools/hsv_decide.py calib [gate] [корпус] — калибровка ряда
                                                          (зона × канал) против
                                                          догадки о каналах
         python tools/hsv_decide.py sign [rise] [gate] [корпус] [manual] [auto]
                                        — событие без догадки, имя по выученной
                                          границе; `auto` — обнаружение автоматом
                                          по max(4 рядов), `manual` — только
                                          клипы с закреплёнными рамками
"""
import json
import os
import re
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hsv_probe as probe  # noqa: E402

# Числа модели. Править по замерам, каждое изменение — отдельным прогоном.
WINDOW = 20           # referenceWindowFrames
PERCENTILE = 0.2      # referencePercentile
SIGMAS = 6.0          # referenceNoiseSigmas
MIN_RISE = 0.06       # referenceMinRise для доли цветных пикселей
MAX_LEVEL = 0.40      # потолок порога: выше доля цветных пикселей не гуляет
GATE = 1.0            # во сколько раз свой подъём обязан перекрыть чужой
GATE_MODE = 'cross-zone'  # 'cross-zone' = против подъёма чужого канала,
                          # 'same-zone'  = против чужого цвета в СВОЕЙ зоне
MEM_MS = 0            # за сколько миллисекунд ЧУЖОГО подъёма смотрит вето.
                      # 0 = только текущий кадр (историческое поведение).
ON_CONFIRM = 2        # кадров подряд для подтверждения включения
OFF_RATIO = 0.6       # гистерезис выключения
OFF_CONFIRM_MS = 400  # как долго держаться ниже OFF-уровня
CLIP_V = 0.97         # V p90 зоны — сенсор на потолке
CLIP_OWN = 0.90       # свой признак почти единица
CLIP_CROSS = 0.20     # и чужой признак заметен -> цвет не доказать
# Правки, которые надо мерить ОТДЕЛЬНО друг от друга (`ablate`): скопом мерить
# нельзя, непонятно, что улучшило, а что ухудшило, и откатывать тогда придётся
# всё вместе. Первые три принесены со стороны (Dart-эксперимент), четвёртая
# выросла из нового корпуса.
FREEZE = False    # не двигать окно «пола», пока ЭТА лампа горит
XCL = False       # не двигать окно зоны, пока горит ЧУЖАЯ лампа (её засветка)
CLIPALL = False   # пересвет ЛЮБОЙ зоны блокирует ОБА канала, а не только свой
EDGE = False      # включение требует роста яркости своей зоны
EDGE_DV = 0.02    # на сколько p90 яркости обязан подняться над своим полом.
                  # Смысл: красная лампа, ЗАЖЖЕННАЯ в кадре, поднимает и warm,
                  # и яркость; warm-всплеск на ПАДАЮЩЕЙ яркости — это не
                  # красная лампа, а остаток после заливающей белой вспышки
                  # (автоэкспозиция приоткрывается, и стена на кадр-два снова
                  # оранжевая). Замерено на 145328: warm 0.17..0.19 ровно на
                  # кадрах выключения, при V 0.62..0.70 против пола 0.76.
# НОСИТЕЛЬ РЕШЕНИЯ: какой ряд (номер зоны, канал) доказывает включение данной
# лампы. По умолчанию стоит историческая ДОГАДКА — белая = cool своей (левой)
# зоны, красная = warm своей (правой) зоны. На офисном стенде она ПЕРЕВЁРНУТА
# пересветом оранжевого колпака (ЖУРНАЛ §36), и порогами это не лечится: его
# вообще не надо угадывать, его надо измерить на калибровке (шаги «2 БЕЛАЯ» и
# «3 КРАСНАЯ»). Режим `calib` ниже мерит, что даёт такое измерение.
W_SEL = (0, 'cool')
R_SEL = (1, 'warm')
ROWS = ((0, 'cool'), (0, 'warm'), (1, 'cool'), (1, 'warm'))
# Признаки для выучиваемой границы (`learn_boundary`): четыре ряда и все
# упорядоченные пары «ряд минус ряд».
FEATURES = ROWS + tuple((a, b) for a in ROWS for b in ROWS if a != b)


def feat_val(e, feat):
    """Значение признака на эпизоде: один ряд или разность двух.

    Одиночный ряд узнаётся по тому, что его первый элемент -- число (номер
    зоны); в паре признаков элемент сам является кортежем.
    """
    if isinstance(feat[0], int):
        return e[feat]
    return e[feat[0]] - e[feat[1]]


def feat_name(feat):
    """Признак по-человечески: «зона1/cool» или «зона1/cool − зона0/cool»."""
    if isinstance(feat[0], int):
        return "зона%d/%s" % feat
    return "зона%d/%s \u2212 зона%d/%s" % (feat[0] + feat[1])


class Series:
    """Скользящее окно одного признака: «пол», шум, размах."""

    def __init__(self):
        self.values = []

    def add(self, v):
        self.values.append(v)
        if len(self.values) > WINDOW:
            self.values.pop(0)

    def pct(self, q):
        if not self.values:
            return None
        return float(np.percentile(np.asarray(self.values), q * 100))

    @property
    def floor(self):
        return self.pct(PERCENTILE)

    @property
    def sigma(self):
        if len(self.values) < 5:
            return 0.0
        return probe.robust_sigma(np.asarray(self.values))

    @property
    def span(self):
        if len(self.values) < 5:
            return None
        return self.pct(0.95) - self.pct(0.05)

    @property
    def ready(self):
        return len(self.values) >= max(5, WINDOW // 2)


class Channel:
    """Один канал: свой признак, чужой признак, автомат состояний."""

    def __init__(self, own, cross):
        self.own = own
        self.cross = cross
        self.lit = False
        self.hot_run = 0
        self.off_since = None
        self.events = []

    def level(self):
        if not self.own.ready:
            return None
        floor = self.own.floor
        max_level = MAX_LEVEL
        span = self.own.span
        if span is not None and span > 0:
            max_level = min(max_level, max(MIN_RISE, 0.5 * span))
        return min(max(MIN_RISE, SIGMAS * self.own.sigma), max_level)

    def rise(self, cur=None):
        if not self.own.ready:
            return None
        # `cur` — значение этого кадра. При заморозке пола кадры горения в окно
        # не попадают, и «последнее значение окна» было бы значением ПОСЛЕДНЕГО
        # ТЁМНОГО кадра: подъём считался бы нулём и вспышка пропадала.
        v = self.own.values[-1] if cur is None else cur
        return max(0.0, v - self.own.floor)

    def cross_rise(self, cur=None):
        if not self.cross.ready:
            return 0.0
        v = self.cross.values[-1] if cur is None else cur
        return max(0.0, v - self.cross.floor)

    def step(self, hot, t_ms, cur=None):
        """Включение — по кадрам подряд; выключение — по длительности провала."""
        if hot:
            self.off_since = None
            self.hot_run += 1
            if not self.lit and self.hot_run >= ON_CONFIRM:
                self.lit = True
                self.events.append({"on_ms": t_ms, "off_ms": None})
        else:
            self.hot_run = 0
            if self.lit:
                floor = self.own.floor
                level = self.level()
                v = self.own.values[-1] if cur is None else cur
                below = floor is not None and level is not None and (
                    v <= floor + OFF_RATIO * level
                )
                if below:
                    if self.off_since is None:
                        self.off_since = t_ms
                    elif t_ms - self.off_since >= OFF_CONFIRM_MS:
                        self.lit = False
                        self.events[-1]["off_ms"] = t_ms
                else:
                    self.off_since = None


def lamp_centers(cool_map, warm_map, n):
    """Где белая и где красная лампа.

    Брать просто «где больше белых пикселей» нельзя: пересвеченная белая лампа
    заливает всю стену, и пик приходится на стену. Ищется ПЕРЕВЕС — в ядре
    своей лампы один признак явно сильнее другого, а на заливаемой стене оба
    растут вместе.
    """
    diff_cool = probe.box((cool_map - warm_map) / n, 25)
    diff_warm = probe.box((warm_map - cool_map) / n, 25)
    pc = probe.peak(diff_cool)
    pw = probe.peak(diff_warm)
    return (pc[0], pc[1]), (pw[0], pw[1])


def build(name, fps=probe.FPS, half=24, centers=None, gain=1.0):
    """Ряды признаков двух зон. Кладёт в %TEMP%/hsvlamp/cache_*, чтобы крутить
    пороги без повторной расшифровки видео.

    Ключ кэша — ПОЛНОЕ имя файла и его размер. Ключ по первым 19 символам
    («PXL_20261123_190609») годился, пока файлы не переименовали: после
    переименования девять РАЗНЫХ записей дают один и тот же префикс, и все
    девять молча читали бы ряды одной видео — пороги подбирались бы по
    дублям, а цифры выглядели бы правдоподобно.
    """
    tag = ("manual_%d_%d_%d_%d" % (centers[0][0], centers[0][1], centers[1][0], centers[1][1])) if centers else "auto"
    if abs(gain - 1.0) > 1e-3:
        # Затемнение сцены имитируется отдельным кэшем: ряды признаков при
        # `gain` другие, и мешать их с оригиналом нельзя.
        tag += "_g%.2f" % gain
    if probe.TONEMAP:
        # HDR-декод с tone-map даёт ДРУГИЕ ряды яркости и насыщенности; без
        # метки в ключе кэш молча подменил бы их non-tone-mapped кадрами.
        tag += "_tm"
    stem = re.sub(r"[^\w.-]", "_", os.path.splitext(name)[0])
    size = os.path.getsize(probe.path_of(name))
    cache = os.path.join(
        probe.OUT, "cache3_%s_%d_%d_%d_%s.npz" % (stem[:70], size // 1024,
                                                  int(fps), half, tag))
    if os.path.exists(cache):
        d = np.load(cache)
        return (
            int(d["n"]),
            [(int(d["wx"]), int(d["wy"])), (int(d["rx"]), int(d["ry"]))],
            [
                {"cool": d["w_cool"], "warm": d["w_warm"], "V": d["w_V"]},
                {"cool": d["r_cool"], "warm": d["r_warm"], "V": d["r_V"]},
            ],
        )
    f = probe.frames(probe.path_of(name), fps=fps)
    if abs(gain - 1.0) > 1e-3:
        # «Чёрные очки»: та же сцена, но темнее в `gain` раз. Проверка того,
        # что нельзя делать «на глаз»: затемнение снижает и яркость, и
        # насыщенность, а окно «тёплого» требует S >= 0.45 — то есть вместе с
        # пересветом оно может убить и сам признак.
        f = np.clip(f.astype(np.float32) * gain, 0, 255).astype(np.uint8)
    n = f.shape[0]
    cool_map = np.zeros((probe.H, probe.W), np.float32)
    warm_map = np.zeros((probe.H, probe.W), np.float32)
    for i in range(n):
        h, s, v = probe.hsv(f[i])
        c, w = probe.cool_warm(h, s, v)
        cool_map += c
        warm_map += w
    if centers is None:
        centers = list(lamp_centers(cool_map, warm_map, n))
    z = [probe.series_in(f, x, y, half) for (x, y) in centers]
    np.savez(
        cache,
        n=n,
        wx=centers[0][0], wy=centers[0][1], rx=centers[1][0], ry=centers[1][1],
        w_cool=z[0]["cool"], w_warm=z[0]["warm"], w_V=z[0]["V"],
        r_cool=z[1]["cool"], r_warm=z[1]["warm"], r_V=z[1]["V"],
    )
    return n, centers, z


def episodes(name, rise=0.08, hold=3, centers=None):
    """Эпизоды включений БЕЗ автомата — «что вообще происходило в кадре».

    Ищется скачок любого из четырёх признаков двух зон (cool/warm каждой) выше
    собственного пола на `rise`, удержанный `hold` кадров. Нужно это потому,
    что автомат на новый корпус ещё не настроен, а сравнивать что-то уже надо:
    список эпизодов не зависит от порога, окна и вето, то есть от того, что
    сейчас подбирается.

    Для каждого эпизода печатаются приращения обеих зон по трём величинам, и
    по ним видно главное: настоящий красный подъём идёт ВМЕСТЕ с ростом
    яркости, а ложный тёплый — на падающем фронте белого (остаток после
    заливающей вспышки: автоэкспозиция успевает приоткрыться, и стена снова
    оранжевая на один кадр).
    """
    if centers is None:
        centers = MANUAL.get(stamp(name))
    n, centers, z = build(name, centers=centers)
    fps = probe.FPS
    e = np.maximum.reduce([z[0]["cool"], z[0]["warm"],
                           z[1]["cool"], z[1]["warm"]])
    floor = float(np.percentile(e, 20))
    hot = e >= floor + rise
    eps, i = [], 0
    while i < n:
        if hot[i] and not hot[max(0, i - 3):i].any():
            j = i
            while j + 1 < n and hot[j + 1]:
                j += 1
            if j - i + 1 >= hold:
                eps.append((i, j))
            i = j + 1
        else:
            i += 1
    rows = []
    for (a, b) in eps:
        k = a + int(np.argmax(e[a:b + 1]))
        p = max(0, a - 15)
        d = {}
        for zi in (0, 1):
            for key, lbl in (("cool", "cool"), ("warm", "warm"), ("V", "dV")):
                d["%s_%s" % ("LR"[zi], lbl)] = (
                    float(z[zi][key][k]) - float(np.median(z[zi][key][p:a + 1])))
        d["t_ms"] = int(a * 1000 / fps)
        d["dur"] = round((b - a + 1) / fps, 2)
        rows.append(d)
    return rows


def episode_rises(name, rise=0.08):
    """Те же эпизоды, но рядом — приращение КАЖДОГО из четырёх рядов.

    Имена ламп здесь нет намеренно: это ровно то, что видит калибровка
    приложения (кадры «фон», «белая горит», «красная горит»), без подсказки о
    том, какой канал что значит.
    """
    return [{row: e["LR"[row[0]] + "_" + row[1]] for row in ROWS}
            for e in episodes(name, rise=rise)]


def learn_selects(names, rise=0.08, scope='any'):
    """Соответствие «лампа → ряд (зона, канал)» из калибровочных состояний.

    Эмуляция шагов «2 БЕЛАЯ» и «3 КРАСНАЯ»: берутся только те клипы группы, чей
    эталон — ОДИН цвет подряд (это и есть «известное состояние лампы»), для
    каждого ряда считается средняя сила эпизодов этого цвета, и носителем
    становится ряд, поднявшийся сильнее всего. Различаются два объёма поиска:

    'any'      — все четыре ряда, то есть доказательством может быть и блик на
                 соседнем колпаке (именно так белая вспышка на офисном стенде
                 даёт больший подъём в ЧУЖОЙ рамке, чем в своей);
    'own-zone' — каждой лампе разрешено искать только в своей рамке (зона 0 для
                 белой, зона 1 для красной): это ровно то, что способна измерить
                 калибровка приложения без перемены местами самих рамок.

    В 'any' ряды обязаны различаться: если оба нуля указывают на один ряд, его
    берёт метка с большим подъёмом, а вторая уходит на следующего кандидата.
    Возвращает ((w_ряд), (r_ряд)) и разбор для печати. Если для какой-то метки
    эталонных клипов нет, там остаётся догадка по умолчанию.
    """
    cand = {"W": [r for r in ROWS if r[0] == W_SEL[0]] if scope == 'own-zone'
            else list(ROWS),
            "R": [r for r in ROWS if r[0] == R_SEL[0]] if scope == 'own-zone'
            else list(ROWS)}
    acc = {lab: {row: [] for row in ROWS} for lab in "WR"}
    used = []
    for name in names:
        t = truth_seq(name)
        if not t or len(set(t)) != 1:
            continue
        rs = episode_rises(name, rise)
        if not rs:
            continue
        used.append("%s=%s×%d" % (stamp(name), t[0], len(rs)))
        for e in rs:
            for row in ROWS:
                acc[t[0]][row].append(e[row])
    means = {lab: {row: (float(np.mean(v)) if v else None)
                   for row, v in d.items()} for lab, d in acc.items()}
    ranked = {lab: sorted((r for r in cand[lab] if means[lab][r] is not None),
                          key=lambda r: -means[lab][r]) for lab in "WR"}
    top = {lab: (means[lab][ranked[lab][0]] if ranked[lab] else -1.0)
           for lab in "WR"}
    sel = {}
    # Первый выбирает тот цвет, у которого подъём больше: у него доказательство
    # сильнее, а проигравшему достаётся следующий кандидат.
    for lab in sorted("WR", key=lambda l: -top[l]):
        for row in ranked[lab]:
            if scope == 'own-zone' or row not in sel.values():
                sel[lab] = row
                break
    for lab, dflt in (("W", W_SEL), ("R", R_SEL)):
        sel.setdefault(lab, dflt)
    return ((sel["W"], sel["R"]),
            {"used": used, "means": means, "ranked": ranked})


def events_any(name, min_rise=None, centers=None):
    """События «произошло включение», найденные автоматом по агрегированному ряду.

    Носитель-detector — максимум четырёх рядов (зона × канал): детектор не
    угадывает, КАКИМ признаком докажется вспышка, он знает только, что в кадре
    что-то стало заметно ярче/цветнее сразу везде. Обнаружение при этом не
    грубое, как в `episodes()`, а тот же самый автомат: скользящий пол по окну
    WINDOW, порог по шуму окна (SIGMAS), подтверждение ON_CONFIRM и гистерезис
    выключения. Замерено: на старом стенде грубый порог по всему клипу теряет
    события (191445_5: 10 вспышек -> 2 эпизода), а скользящий пол их видит.

    Возвращает тот же формат, что `episode_rises`: приращения четырёх рядов на
    пике события плюс `t_ms`/`dur`.
    """
    global MIN_RISE
    saved = MIN_RISE
    if min_rise is not None:
        MIN_RISE = min_rise
    if centers is None:
        centers = MANUAL.get(stamp(name))
    n, centers, z = build(name, centers=centers)
    arr = {(zi, key): z[zi][key]
           for zi in (0, 1) for key in ("cool", "warm")}
    agg = np.maximum.reduce(list(arr.values()))
    ch = Channel(Series(), Series())
    for i in range(n):
        t = int(round(i * 1000 / probe.FPS))
        ch.own.add(agg[i])
        ch.cross.add(agg[i])
        lvl = ch.level()
        if lvl is None:
            continue
        ch.step(ch.rise(agg[i]) > lvl, t, agg[i])
    out = []
    for e in ch.events:
        a = int(e["on_ms"] * probe.FPS / 1000.0)
        b = int(((e["off_ms"] if e["off_ms"] is not None
                  else e["on_ms"] + 400) * probe.FPS / 1000.0))
        b = max(a, min(b - 1, n - 1))
        k = a + int(np.argmax(agg[a:b + 1]))
        p = max(0, a - 15)
        d = {r: float(arr[r][k]) - float(np.median(arr[r][p:a + 1]))
             for r in arr}
        d["t_ms"] = e["on_ms"]
        d["dur"] = round((b - a + 1) / probe.FPS, 2)
        out.append(d)
    MIN_RISE = saved
    return out


def learn_boundary(clips, rise=0.08, sig=None):
    """Граница «белая / красная», выученная на известных состояниях лампы.

    Другая структура решения, чем в `decide()`: там событие обязано быть
    подъёмом ЗАРАНЕЕ выбранного ряда, и ошибка в выборе ряда стоит дороже всего
    (на офисном стенде белая лампа в своей рамке даёт +0,03, то есть не видна
    вовсе). Здесь детектор слепо ищет «в кадре что-то включилось» (эпизод =
    подъём МАКСИМУМА четырёх рядов выше своего пола), а имя события решает
    граница, выстроенная на калибровке.

    Признаком может быть и один ряд, и РАЗНОСТЬ двух рядов: вторые покрывают
    историческое «cool против warm» (там классы противолежат, и абсолютная сила
    ничего не говорит), первые -- случай офисного стенда (там оба класса дают
    подъём одного и того же ряда, но в 40 раз разные по силе). Перебираются все
    4 ряда и все 12 упорядоченных пар; выбирается вариант с наибольшей чистотой
    разделения |среднее W − среднее R| / средний разброс, порог -- разрыв между
    классами с наименьшей ошибкой на обучающих эпизодах.

    Возвращает {"feat", "thr", "high", "means", "sep", "n", "used"} или None, если
    в клипах нет обоих состояний (тогда и называть события нечем).
    """
    by_lab = {"W": [], "R": []}
    used = []
    sigf = sig or (lambda n: episode_rises(n, rise))
    for name in clips:
        t = truth_seq(name)
        if not t or len(set(t)) != 1:
            continue
        eps = sigf(name)
        if not eps:
            continue
        used.append("%s=%s\u00d7%d" % (stamp(name), t[0], len(eps)))
        by_lab[t[0]] += eps
    if not by_lab["W"] or not by_lab["R"]:
        return None
    best = None
    for feat in FEATURES:
        wv = np.array([feat_val(e, feat) for e in by_lab["W"]], np.float32)
        rv = np.array([feat_val(e, feat) for e in by_lab["R"]], np.float32)
        spread = (float(wv.std()) + float(rv.std())) / 2 + 1e-3
        sep = abs(float(wv.mean()) - float(rv.mean())) / spread
        if best is None or sep > best[0]:
            best = (sep, feat, wv, rv)
    sep, feat, wv, rv = best
    # Порог: разрыв между классами на выбранном признаке. Перебираются все
    # середины между соседними значениями; берётся вариант с наименьшим числом
    # ошибок, при равенстве -- с наибольшим зазором.
    vals = sorted(set([round(float(x), 4) for x in np.concatenate([wv, rv])]))
    high = "W" if wv.mean() >= rv.mean() else "R"
    hi_vals, lo_vals = (wv, rv) if high == "W" else (rv, wv)
    cand = None
    for i in range(len(vals) - 1):
        thr = (vals[i] + vals[i + 1]) / 2.0
        err = int((hi_vals < thr).sum() + (lo_vals >= thr).sum())
        gap = vals[i + 1] - vals[i]
        if cand is None or (err, -gap) < (cand[0], -cand[1]):
            cand = (err, gap, thr)
    err, gap, thr = cand
    return {"feat": feat, "thr": thr, "high": high, "gap": gap,
            "train_err": err, "sep": sep,
            "means": (float(wv.mean()), float(rv.mean())),
            "n": (len(by_lab["W"]), len(by_lab["R"])), "used": used}


def tape(name, cls, rise=0.08, sig=None):
    """Лента событий клипа, названных выученной границей (без догадки о каналах)."""
    eps = (sig or (lambda n: episode_rises(n, rise)))(name)
    seq = ""
    other = "R" if cls and cls["high"] == "W" else "W"
    for e in eps:
        if cls is None:
            seq += "?"
            continue
        seq += cls["high"] if feat_val(e, cls["feat"]) >= cls["thr"] else other
    return eps, seq


def tape_err(truth, seq):
    """Цена ленты против эталона: лишние + пропущенные по общей подпоследовательности."""
    hit = lcs_len(truth, seq)
    return len(seq) - hit + len(truth) - hit


def ambient(name, fps=probe.FPS):
    """Яркость и ЦВЕТ ВСЕГО КАДРА по кадрам: V p50, доли cool и warm, плюс
    ДАЛЬНИЙ ФОН (нижняя треть кадра — пол, люди, стена вне засветки лампы).

    Нужно чтобы отличить переключение ЛАМПЫ от переключения СВЕТА В ЗАЛЕ: лампа
    поднимает своё пятно сильнее, чем весь кадр, а люстра поднимает кадр целиком
    ровно настолько же, насколько и зону. Дальний фон берётся нижней третью
    кадра: верхняя полоса у нас всегда выбита, середина — это и есть лампы.
    Ряды кэшируются отдельно от `build()`, по тому же ключу (имя + размер +
    метка tone-map).

    ПРОВЕРЕНО 24.11.2026, ЖУРНАЛ §35: признак годится ровно на один случай —
    белая лампа на Pixel (её dV +0,24 при дальнем фоне −0,02…+0,02), и только
    там, где автомат и так прав. Красная лампа поднимает дальний фон на
    столько же, на сколько саму зону (0,016–0,024 против 0,01–0,05), а на iPhone
    даже белая даёт фон +0,03…+0,13. Порог «зона − фон < θ» по 59 настоящим и
    15 заловым эпизодам: θ=0,05 режет 8/15 ложных и 19/59 настоящих. Вето в
    `decide()` отсюда НЕ сделано — размен хуже 1:2 при любом θ.
    """
    stem = re.sub(r"[^\w.-]", "_", os.path.splitext(name)[0])[:70]
    tag = "_tm" if probe.TONEMAP else ""
    size = os.path.getsize(probe.path_of(name))
    cache = os.path.join(probe.OUT, "ambient2_%s_%d_%d%s.npz"
                         % (stem, size // 1024, int(fps), tag))
    if os.path.exists(cache):
        d = np.load(cache)
        return d["V"], d["cool"], d["warm"], d["far"]
    f = probe.frames(probe.path_of(name), fps=fps)
    n, h, w = f.shape[0], f.shape[1], f.shape[2]
    v50 = np.zeros(n, np.float32)
    far = np.zeros(n, np.float32)
    cool = np.zeros(n, np.float32)
    warm = np.zeros(n, np.float32)
    y0 = int(h * 2 / 3)
    for i in range(n):
        hh, ss, vv = probe.hsv(f[i])
        c, wm = probe.cool_warm(hh, ss, vv)   # ss нужен только внутри cool_warm
        v50[i] = np.percentile(vv, 50)
        far[i] = np.percentile(vv[y0:, :], 50)
        cool[i] = c.mean()
        warm[i] = wm.mean()
    np.savez(cache, V=v50, cool=cool, warm=warm, far=far)
    return v50, cool, warm, far


def decide(name, fps=probe.FPS, half=24, gate=None, sigmas=None, min_rise=None,
           centers=None, gate_mode=None, mem=None, carrier='hsv', gain=1.0,
           freeze=None, xcl=None, clipall=None, edge=None, edge_dv=None,
           w_sel=None, r_sel=None):
    """Автомат счёта. `carrier` меняет ТОЛЬКО носитель решения:

    'hsv'  — доля цветных пикселей своей зоны (модель v5);
    'luma' — p90 яркости своей зоны (то, чем решает живой отсчёт v4, и то, что
            означает совет «не смотреть на цвет, главное — зафиксировать
            вспышку»). Окно, пол, шум, порог, вето и гистерезис при этом
            идентичны: сравнение честное, разница только в признаке.
    """
    global GATE, SIGMAS, MIN_RISE, GATE_MODE, MEM_MS, FREEZE, XCL, CLIPALL
    global EDGE, EDGE_DV
    if edge is not None:
        EDGE = edge
    if edge_dv is not None:
        EDGE_DV = edge_dv
    if gate is not None:
        GATE = gate
    if sigmas is not None:
        SIGMAS = sigmas
    if min_rise is not None:
        MIN_RISE = min_rise
    if gate_mode is not None:
        GATE_MODE = gate_mode
    if mem is not None:
        MEM_MS = mem
    if freeze is not None:
        FREEZE = freeze
    if xcl is not None:
        XCL = xcl
    if clipall is not None:
        CLIPALL = clipall
    if centers is None:
        centers = MANUAL.get(stamp(name))
    n, centers, z = build(name, fps, half, centers, gain)
    wz, wc = w_sel if w_sel is not None else W_SEL
    rz, rc = r_sel if r_sel is not None else R_SEL
    white_cool, white_warm, white_v = z[wz]["cool"], z[wz]["warm"], z[wz]["V"]
    red_cool, red_warm, red_v = z[rz]["cool"], z[rz]["warm"], z[rz]["V"]
    if carrier == 'luma':
        # Носитель — яркость: своё = p90 своей зоны, чужое = p90 чужой зоны.
        # Вето по цвету в своей зоне здесь не о чем говорить, только cross-zone.
        w_own_a, w_cross_a = white_v, red_v
        r_own_a, r_cross_a = red_v, white_v
        if gate_mode is None:
            GATE_MODE = 'cross-zone'
    else:
        # Ряд носителя выбирается калибровкой: у каждой лампы свой (зона,
        # канал), «чужим» для вето same-zone остаётся ВТОРОЙ канал той же
        # выбранной зоны. При W_SEL/R_SEL по умолчанию это ровно прежнее
        # поведение (белая = cool левой зоны, красная = warm правой).
        w_own_a = white_cool if wc == 'cool' else white_warm
        w_cross_a = white_warm if wc == 'cool' else white_cool
        r_own_a = red_warm if rc == 'warm' else red_cool
        r_cross_a = red_cool if rc == 'warm' else red_cool
    ch_w = Channel(Series(), Series())
    ch_r = Channel(Series(), Series())
    v_w, v_r = Series(), Series()   # яркость своей зоны — для проверки фронта
    w_hist, r_hist = [], []  # подъёмы по времени — память для вето
    for i in range(n):
        t = int(round(i * 1000 / fps))
        # Заморозка «пола». Пока канал подтверждённо горит, его кадры в окно не
        # идут: длинное горение поднимает пол до себя же, и следующие вспышки
        # перестают быть подъёмом (случай `225034`: «горят обе» -> 0 событий).
        # XCL — то же для чужого горения: свет соседней лампы лежит в ЭТОЙ зоне
        # и портит её пол, хотя эта лампа не горела.
        w_frozen = (FREEZE and ch_w.lit) or (XCL and ch_r.lit)
        r_frozen = (FREEZE and ch_r.lit) or (XCL and ch_w.lit)
        if not w_frozen:
            ch_w.own.add(w_own_a[i])
            ch_w.cross.add(w_cross_a[i])
        if not r_frozen:
            ch_r.own.add(r_own_a[i])
            ch_r.cross.add(r_cross_a[i])
        wl, rl = ch_w.level(), ch_r.level()
        # Пересвет: зона на потолке сенсора, свой признак почти единица, а чужой
        # заметен — по цвету не доказать, какая лампа там горела.
        w_amb = white_v[i] >= CLIP_V and white_cool[i] >= CLIP_OWN and white_warm[i] >= CLIP_CROSS
        r_amb = red_v[i] >= CLIP_V and red_warm[i] >= CLIP_OWN and red_cool[i] >= CLIP_CROSS
        if CLIPALL and (w_amb or r_amb):
            # Пересвет ЛЮБОЙ зоны гасит оба канала: залитая белым сцена не
            # доказывает, что красная лампа была красной даже в другой рамке.
            w_amb = r_amb = True
        if wl is None or rl is None:
            continue
        w_rise, r_rise = ch_w.rise(w_own_a[i]), ch_r.rise(r_own_a[i])
        # ФРОНТ. Тот же автомат, но дополнительное требование к обоим каналам:
        # яркость СВОЕЙ зоны обязана расти. warm-всплеск при падающей яркости
        # — остаток после белой вспышки, а не красная лампа (замерено: 8
        # ложных красных на чисто белой 145328 сидят ровно на кадрах
        # выключения). Проверка симметричная, потому что и на падающем фронте
        # красной cool ведёт себя так же.
        v_w.add(white_v[i])
        v_r.add(red_v[i])
        w_edge_ok = not EDGE or (not v_w.ready or
                                 white_v[i] - v_w.floor >= EDGE_DV)
        r_edge_ok = not EDGE or (not v_r.ready or
                                 red_v[i] - v_r.floor >= EDGE_DV)
        # ВЕТО с ПАМЯТЬЮ. Зажженная лампа поднимает признак ЧУЖОЙ зоны на
        # кадр-два раньше, чем её собственный (засветка сцены и автоэкспозиция),
        # поэтому сравнение подъёмов одного кадра такое перетекание пропускает:
        # белая вспышка на 0.5 с раньше красной даёт ложное белое включение.
        # MEM_MS = 0 оставляет историческое поведение — только текущий кадр.
        w_hist.append((t, w_rise if w_rise is not None else 0.0))
        r_hist.append((t, r_rise if r_rise is not None else 0.0))
        while w_hist and w_hist[0][0] < t - MEM_MS:
            w_hist.pop(0)
        while r_hist and r_hist[0][0] < t - MEM_MS:
            r_hist.pop(0)
        # ЧУЖОЙ, против которого работает вето: подъём чужого канала (его зоны)
        # или чужой цвет в СВОЕЙ зоне. Правила разные, проверять приходится оба.
        if GATE_MODE == 'same-zone':
            w_block, r_block = (ch_w.cross_rise(w_cross_a[i]),
                                ch_r.cross_rise(r_cross_a[i]))
        else:
            w_block = max(v for _, v in r_hist)
            r_block = max(v for _, v in w_hist)
        hot_w = (
            not w_amb
            and w_rise is not None
            and w_rise > wl
            and w_rise >= GATE * w_block
            and w_edge_ok
        )
        hot_r = (
            not r_amb
            and r_rise is not None
            and r_rise > rl
            and r_rise >= GATE * r_block
            and r_edge_ok
        )
        ch_w.step(hot_w, t, w_own_a[i])
        ch_r.step(hot_r, t, r_own_a[i])
    return {
        "file": name,
        "gate": GATE,
        "gate_mode": GATE_MODE,
        "mem_ms": MEM_MS,
        "whiteZone": centers[0],
        "redZone": centers[1],
        "white_events": len(ch_w.events),
        "red_events": len(ch_r.events),
        "white_ms": [e["on_ms"] for e in ch_w.events],
        "red_ms": [e["on_ms"] for e in ch_r.events],
        # Границы событий целиком — нужны `tools/hsv_stats.py`, чтобы мерить
        # амплитуду именно на тех включениях, которые модель посчитала.
        "white_spans": [[e["on_ms"], e["off_ms"]] for e in ch_w.events],
        "red_spans": [[e["on_ms"], e["off_ms"]] for e in ch_r.events],
        "lit_at_end": [ch_w.lit, ch_r.lit],
    }


# ---------------------------------------------------------------------------
# Человеческая разметка. Заказчик 23.11.2026 продиктовал ПОРЯДОК включений для
# ВСЕХ записей (б = белая, к = красная); ключ — идентификатор из stamp(), то
# есть номер записи со слов заказчика, а не имя файла. Это единственный эталон,
# которым можно проверить модель: без него «46/40» было только согласованностью
# модели с собой. Запись «4» (191034) размечена словами («красной нет»), но
# файла в папке сейчас нет — проверить её нельзя.
#
# Переиздиктовка 24.11.2026: заказчик подтвердил СВЕЖУЮ расшифровку и она
# взята вместо прежней по записям 1 (190609: было 10 событий, стало 8 —
# `кбкбкккб`, совпадает со старой версией эталона из `truth15.log`), 10
# (191508) и 11 (191445): обе `кбккбкб`. Остальные девять записей новая
# диктовка с прежней разметкой не расходится.
# ---------------------------------------------------------------------------
TRUTH = {
    "190609": "RWRWRRRW",
    "190707": "RWRRWRW",
    "190736": "RWRRWRWW",
    # «все белые с обоих сторон по очереди, красной тут нет» — число белых не
    # размечено, взято то, что нашла модель; проверяется только «красных = 0».
    "191034": "WWWWW",
    "191142": "WRRR",
    "191158": "WRWRWR",
    "191315": "WRWRWRWR",
    "191344": "RWRWRWRW",
    "191407": "RWRWR",
    "191508": "RWRRWRW",
    "191445_1": "RWRRWRW",
    # Свежая партия 23:47–23:50, размечена 24.11.2026. Одна лампа в кадре —
    # значит событий второй обязано быть НОЛЬ, и это единственный на сегодня
    # тест на ложные срабатывания.
    "191445_2": "WWWWW",        # 5 раз белая
    "191445_3": "WWWWWW",       # 6 белых
    "191445_4": "RRRRRR",       # 6 красных
    "191445_5": "W" * 10,       # 10 белых
    "191445_6": "R" * 8,        # 8 красных
    # "191445_7": обе лампы горят одновременно — порядка и числа заказчик не
    # назвал, в эталон не берётся: проверять на ней нечего, кроме факта слипания.
}

# Съёмка в офисе 24.11.2026. Расшифровка там — СТРОКИ ПЛАНА («8Б», «12К»),
# имён файлов в ней нет, поэтому сначала была получена лента эпизодов, НИКАК
# не связанная с автоматом (`events`): эпизод = скачок любого из четырёх
# признаков двух зон выше собственного пола, удержанный 3 кадра. ВРЕМЕНА
# эпизодов и их СИЛА из этой таблицы верны и сейчас, а ВОТ ЦВЕТ, который
# таблица присваивала («cool перевесил = белая»), 25.11.2026 оказался
# ПЕРЕВЁРНУТЫМ для этого стенда — см. большой комментарий внутри блока ниже.
# Различаются два класса эпизодов, и это единственное надёжное различие:
#   СИЛЬНЫЙ: dV +0,24, cool +0,55…+0,67, ореол вокруг лампы hue 15-17°;
#   СЛАБЫЙ:  dV +0,05, warm +0,10…+0,14 в чужой зоне, own cool +0,05.
# Сильный = красная, слабый = белая (со слов заказчика по `145804`).
TRUTH.update({
    # !!! 25.11.2026: цвета в этом корпусе ОКАЗАЛИСЬ ПЕРЕВЁРНУТЫ. Разметка
    # ниже — НЕ вывод таблицы эпизодов, а слово заказчика (`145804`: «что вижу
    # на видео — Б К К Б К Б Б К») плюс три независимых проверки: (а) оттенок
    # ореола вокруг лампы в пике вспышки (у сильных событий медианный hue 15-17°
    # = оранжевый, у слабых S=0,01 = нейтральный); (б) кадрики ламп в пике
    # эпизода (сильный = оранжевый колпак выбило в белое пятно, слабый = белая
    # колба светит, а соседний оранжевый колпак светится ОТ БЕЛИКА);
    # (в) `IMG_3399` с EV -2, где красная ещё НЕ выбита и даёт warm=1,00.
    # То есть на этом стенде: СИЛЬНЫЙ cool-подъём = КРАСНАЯ лампа (её колпак
    # выбит в белый), СЛАБЫЙ warm-подъём = БЕЛАЯ лампа (блик на оранжевом
    # колпаке соседней сильнее, чем собственная сигнальная белая колба).
    # Признак «cool перевесил = белая» здесь НЕВЕРЕН, и порогами он не лечится.
    "145328": "R" * 8,          # 8 сильных = красная 8 подряд
    "145500": "W" * 12,         # 12 слабых = белая 12 подряд, без пауз
    "145545": "R" * 12,         # 12 сильных = красная 12 подряд
    "145954": "WRWRWRWRWR",     # лента из 10: чередование, начиная со слабой
    # `145804` — единственный клип, размеченный СЛОВОМ заказчика, а не
    # признаками: «что вижу на видео — Б К К Б К Б Б К». Он и вскрыл переворот:
    # его 8 эпизодов ровно делятся на 4 сильных (3,40; 5,33; 8,87; 14,27 с) и 4
    # слабых (1,60; 7,00; 10,80; 12,67 с), и заказчик называет сильными КРАСНЫЕ,
    # а слабыми БЕЛЫЕ. Всё остальное в этом блоке — та же логика, перенесённая
    # на соседние клипы по форме сигнала.
    "145804": "WRRWRWWR",       # 25.11.2026, со слов заказчика
    # 145027 и 145128 названы заказчиком 25.11.2026 (до этого оба стояли в
    # «не размечено»). По его словам и с его же объяснением моей ошибки:
    #   145027 = 7 белых. Отблеск БЕЛОЙ лампы на оранжевом плафоне соседней
    #   красной выглядит как «и та горит», но красных пикселей там нет — то
    #   есть подъём чужой зоны несёт блик, а не свет красной лампы.
    #   145128 = 2 красных, очень слабых: лампа светит ВВЕРХ, плафон её
    #   закрывает, вверх уходит только лёгкий красный. Это самый тусклый
    #   красный во всём корпусе и проверка порога детекции, а не именования.
    "145027": "W" * 7,
    "145128": "R" * 2,
    "IMG_3395": "W" * 8,      # ряд 26: вторая пара, белая 8
    "IMG_3399": "WWWWRRRR",   # ряд 31: EV -2, 4Б + 4К
    # Ряды «60 с молчания, люди ходят, свет зала». Заказчик подтвердил
    # 24.11.2026: лампы в этих клипах НЕ переключались, горел только свет
    # зала. Это единственный в новом корпусе тест на ложные срабатывания:
    # любое событие здесь — ошибка, и считать ошибкой надо ровно столько, сколько
    # модель сама назвала. Претенденты два: 150103 (53,5 с) и 150217 (33,8 с);
    # в обоих таблица эпизодов видит переключения СВЕТА (dV +0,4..+0,8 при
    # cool +0,4 по обеим зонам), а не лампы. Если заказчик назовёт среди них
    # только один, второй убирается отсюда вместе с их числами.
    "150103": "",             # ряд 10: молчание, ходят люди, меняется свет
    "150217": "",             # ряд 10: то же повторно
})
# Не размечены и почему:
# 150448 и 150537 («горит 30 с подряд»: переключение осталось ДО первого
# кадра, детектировать нечего), IMG_3396/3397/3398 (на айфоне при автоэкспозиции
# обе лампы выбиты в белый: warm не растёт даже на красной, цвета в пикселях
# просто нет).
TRUTH_SOFT = {"191034"}  # число белых тут не размечено

# Где стоят лампы в новой партии. Автопоиск по накопленной карте кадра тут
# провалился: камера ходит в руках, и рамка уезжает на стену или в нижний край
# кадра (224926: `cool` пик на (71,359) при высоте кадра 360). Координаты сняты
# с сетки на кадрах, где лампа горит, — ровно так, как оператор ставит ROI в
# приложении руками.
MANUAL = {
    "191445_2": [(470, 150), (170, 170)],
    "191445_3": [(370, 240), (300, 250)],
    "191445_4": [(390, 175), (150, 180)],
    "191445_5": [(215, 175), (60, 180)],
    "191445_6": [(390, 175), (170, 190)],
    "191445_7": [(300, 180), (60, 190)],
}

# Съёмка в офисе 24.11.2026: центры новых корпусов. Сняты НЕ на глаз:
# `hsv_probe.py lamps <папка>` ищет пик разности V(самый цветной кадр) −
# V(самый тёмный) и печатает H/S/V вокруг него; белая лампа — левый пик,
# красная — правый (на листе `lit` у красной виден оранжевый колпак). Кадры,
# где лампа не находится двумя устойчивыми пиками (150730 — общий план с
# сидящим человеком, 150954 — камера уехала вниз, 145128 и IMG_3396 — пик
# приходится на руку), оставлены без центров: ставить рамку наугад хуже,
# чем не ставить вовсе, и на них счёт просто не ведётся.
MANUAL.update({
    # Pixel, офис: белая (252,150), красная (322,150) — один и тот же штатив
    # в 10 клипах подряд.
    **{k: [(252, 150), (322, 150)] for k in (
        "145027", "145328", "145500", "145545", "145804", "145954",
        "150103", "150217", "150448", "150537")},
    # iPhone, вторая пара ламп: пики той же процедуры, клип к клипу камера
    # сдвигается, поэтому центры у каждого свои.
    "IMG_3395": [(274, 142), (348, 125)],
    "IMG_3397": [(275, 143), (347, 125)],
    "IMG_3398": [(263, 139), (345, 125)],
    "IMG_3399": [(275, 138), (366, 140)],
})

# 25.11.2026, §42: `145027` и `145128` сняты НЕ на том стенде, что остальные
# девять клипов этого блока. На кадрах видно другую установку: две лампы на
# гибких ножках торчат ВВЕРХ перед белой стеной, плафоны тёмные. Центры здесь
# не угаданы: (330,130) — вершина разности кадров на вспышке (там же и на
# шести других вспышках), то есть пятно света; «белая слева, красная справа» —
# слово заказчика. Прежние штативные центры (252,150)/(322,150) стоят на 80 px
# левее и ловят не плафон, а стену: на них `145027` даёт 4 события из 7.
MANUAL.update({
    "145027": [(330, 130), (400, 130)],
    "145128": [(330, 130), (400, 130)],
})

# 25.11.2026, §45: разметка координат РУКОЙ заказчика. Способ: на каждый клип
# выдан кадр (30 % длительности, 640x360 — та же шкала, что у анализа), поверх
# него зелёными прямоугольниками обведены плафоны, левый = белая, правый =
# красная. Рамки найдены по зелёным пикселям, их центры переведены в шкалу
# кадра. Это заменяет все прежние центры новых корпусов: штативная пара
# (252,150)/(322,150) сидела НЕ на плафонах — белая рамка на 12 px правее и на
# 26 px НИЖЕ размеченной, красная на 22 px левее и на ~25 px ниже; обе ловили
# корпус и ножку, а не световое пятно.
# Один файл (`IMG_3395`) редактор сдвинул на (+96, +54) без изменения масштаба
# (остаток сверки с настоящим кадром 0.27 против 25.7 без сдвига) — сдвиг
# измерен и убран; у остальных 17 сдвиг нулевой.
MANUAL.update({
    "145027": [(240, 124), (344, 120)],
    "145128": [(241, 122), (345, 118)],
    "145328": [(240, 120), (340, 130)],
    "145500": [(240, 119), (340, 129)],
    "145545": [(241, 124), (340, 130)],
    "145804": [(240, 124), (340, 129)],
    "145954": [(241, 122), (341, 128)],
    "150103": [(239, 121), (341, 129)],
    "150217": [(242, 124), (342, 132)],
    "150448": [(240, 124), (340, 130)],
    "150537": [(242, 124), (342, 128)],
    # Два клипа, которые раньше стояли без центров и поэтому не считались:
    # 150730 — общий план с сидящим человеком (лампы мелкие, 42 px друг от
    # друга), 150954 — камера уехала вниз (y ~ 196 вместо ~ 124).
    "150730": [(272, 171), (314, 173)],
    "150954": [(206, 198), (322, 194)],
    "IMG_3395": [(269, 104), (364, 104)],
    "IMG_3396": [(270, 104), (364, 107)],
    "IMG_3397": [(271, 103), (364, 105)],
    "IMG_3398": [(272, 104), (365, 108)],
    "IMG_3399": [(270, 98), (365, 104)],
})

# Номер записи со слов заказчика -> время съёмки. Соответствие выставлено НЕ по
# именам (они переименованы), а по содержимому: каждый файл прогнан через тот
# же пайплайн и сравнен с сохранёнными рядами оригиналов; ошибка совпадения
# 0.0000 у всех девяти переименованных и у `191445`. Запись «4» (191034) в
# папке отсутствует — её надо вернуть, иначе разметка «красной тут нет»
# непроверяема.
ORDER = {
    "1": "190609", "2": "190707", "3": "190736", "4": "191034",
    "5": "191142", "6": "191158", "7": "191315", "8": "191344",
    "9": "191407", "10": "191508",
}


def stamp(name):
    """Идентификатор записи: время съёмки + номер копии, если он есть.

    Просто номера копии мало: в папке лежат ДВЕ партии с одинаковыми
    суффиксами — `190609262_1 (2)` и `191445559_1 (2)` это разные записи, и
    прежде такой ключ подменял одну другой. Для старой партии время в имени
    потерялось при переименовании, поэтому там ORDER[(N)] восстановлен ПО
    СОДЕРЖИМОМУ (ряды признаков совпали с оригиналами с ошибкой 0.0000).
    """
    m = re.search(r"PXL_\d{8}_(\d{6})", name)
    if m:
        base = m.group(1)
    else:
        # Новые папки (`PXL_20261124_*` идут тем же regexом, `IMG_3395` — нет)
        # не несут ни потерянного времени, ни копий: там идентификатор = имя
        # файла без расширения, иначе `name[13:19]` дал бы пустой ключ.
        base = os.path.splitext(name)[0]
    k = re.search(r"\((\d+)\)", name)
    if not k:
        return base
    if base == "190609":
        return ORDER.get(k.group(1), k.group(1))
    return "%s_%s" % (base, k.group(1))


def truth_seq(name):
    return TRUTH.get(stamp(name))


def group_of(name):
    """Откуда запись: 'стенд' | 'pixel' | 'pixel-стена' | 'iphone' | 'original'.

    Нужна потому, что корпуса нельзя смешивать в одном числе: старый корпус
    снимался с одним набором ламп и разметкой по слову заказчика, новые — с
    ДРУГОЙ парой ламп (iphone) и в другой комнате. Ошибки по ним считаются
    отдельно, иначе «улучшение» на одном корпусе перекрывает провал на другом.

    `original` — настоящее изделие (маячок и красный купол), а не макет с
    печатными колпаками; размечать его надо отдельно уже поэтому (§40).
    """
    d = os.path.normpath(os.path.dirname(probe.path_of(name)))
    labels = dict(zip([os.path.normpath(p) for p in probe.DIRS],
                      ("стенд", "pixel", "iphone", "original")))
    g = labels.get(d, "?")
    # Две записи этого корпуса сняты не на макете с колпаками, а на установке
    # «лампы торчат вверх перед стеной» (§42). Семантика каналов там обратная:
    # белая вспышка даёт большой подъём `cool`, тогда как на макете большой
    # `cool` означает красную. Держать их в одной группе нельзя — проверено
    # 25.11.2026: с правильными рамками на `145027` граница макета переучилась
    # и поломала весь корпус (145500 с 0 ошибок дал 23, IMG_3395 и IMG_3399 —
    # 17 и 16 вместо 0). Отдельной группой они учат свою границу.
    if g == "pixel" and stamp(name) in ("145027", "145128"):
        return "pixel-стена"
    return g


def model_seq(res):
    """События обеих ламп одной лентой в хронологическом порядке."""
    ev = [(t, 'W') for t in res["white_ms"]] + [(t, 'R') for t in res["red_ms"]]
    return ''.join(c for _, c in sorted(ev, key=lambda x: x[0]))


def lcs_len(a, b):
    """Длина максимальной общей подпоследовательности (порядок важен)."""
    prev = [0] * (len(b) + 1)
    for i in range(1, len(a) + 1):
        cur = [0]
        for j in range(1, len(b) + 1):
            cur.append(prev[j - 1] + 1 if a[i - 1] == b[j - 1]
                       else max(prev[j], cur[j - 1]))
        prev = cur
    return prev[-1]


def score(name, res):
    """Сравнение ленты модели с разметкой: сошлось / лишние / пропущено."""
    truth, model = truth_seq(name), model_seq(res)
    if truth is None:
        return None
    hit = lcs_len(truth, model)
    return {
        "file": name,
        "truth": truth,
        "model": model,
        "tW": truth.count('W'), "tR": truth.count('R'),
        "mW": model.count('W'), "mR": model.count('R'),
        "hit": hit, "extra": len(model) - hit, "missed": len(truth) - hit,
        "soft": stamp(name) in TRUTH_SOFT,
    }


def penalty(s):
    """Цена одного клипа: лишние + пропущенные. Для `TRUTH_SOFT` (число белых
    не размечено) лишние белые не в счёт — их сравнивать не с чем.
    """
    p = s["extra"] + s["missed"]
    if s["soft"]:
        p = s["extra"] - min(s["extra"], max(0, s["mW"] - s["tW"]))
    return p


def run_all(only=None, **kw):
    """Прогон по всем размеченным видео, возврат (результаты, сумма ошибок).

    Неразмеченные записи пропускаются ДО decide(): в папке лежат видео без
    разметки и битые файлы (нет `moov atom`), и decode-ошибка одного из них
    не должна ронять всю сверку. `only` оставляет один корпус ('pixel' и т.п.).
    """
    rows, err = [], 0
    for name in probe.videos():
        if truth_seq(name) is None:
            continue
        if only and only != "all" and group_of(name) != only:
            continue
        res = decide(name, **kw)
        s = score(name, res)
        if s is None:
            continue
        p = penalty(s)
        rows.append((p, s))
        err += p
    return rows, err


def report(rows, err, tag):
    print(tag, flush=True)
    for penalty, s in rows:
        print("  %s  эталон=%-9s модель=%-11s W%d/R%d против W%d/R%d  "
              "сошлось=%d лишние=%d пропущено=%d%s"
              % (stamp(s["file"]), s["truth"], s["model"], s["tW"], s["tR"],
                 s["mW"], s["mR"], s["hit"], s["extra"], s["missed"],
                 "  (число белых не размечено)" if s["soft"] else ""),
              flush=True)
    print("  ИТОГО ошибок: %d" % err, flush=True)
    groups = {}
    for penalty, s in rows:
        g = groups.setdefault(group_of(s["file"]), [0, 0])
        g[0] += penalty
        g[1] += 1
    print("  по корпусам: " + ", ".join(
        "%s=%d (%d запис.)" % (g, v[0], v[1])
        for g, v in sorted(groups.items())), flush=True)


def pick(args, default_rise=0.08):
    """Разбор фильтров режимов `events`/`amb`: (rise, список клипов).

    Аргументы: сначала порог (обязательно с точкой), потом имена корпусов,
    «new» или штампы отдельных клипов. Штамп — это цифровое слово БЕЗ точки,
    поэтому не путается с порогом. Штампы тут нужны потому, что `ambient()`
    стоит ДЕКОДИРОВАНИЕ файла, и гонять его по всем 27 роликам ради двух
    клипов — значит ждать полчаса вместо ответа.
    """
    rest = list(args[1:])
    rise = default_rise
    if rest and re.fullmatch(r"[\d]*\.\d+", rest[0]):
        rise = float(rest.pop(0))
    known = {group_of(n) for n in probe.videos()}
    groups = [a for a in rest if a in known or a == "new"]
    wanted = {a for a in rest if a not in groups}
    if "new" in groups:
        names = probe.videos_of(probe.DIRS[1:])
    elif groups:
        names = [n for n in probe.videos() if group_of(n) in groups]
    else:
        names = probe.videos()
    if wanted:
        names = [n for n in names if stamp(n) in wanted]
    return rise, names


if __name__ == "__main__":
    args = sys.argv[1:]
    if args and args[0] == "cache":
        for name in probe.videos():
            build(name)
            print("cached", name, flush=True)
    elif args and args[0] == "sweep":
        rest = args[1:]
        mode = None
        if rest and not rest[0].replace('.', '', 1).isdigit():
            mode, rest = rest[0], rest[1:]
        gates = [float(x) for x in rest] or [1.0, 1.5, 2.0, 3.0]
        halves = [24]
        for half in halves:
            for gate in gates:
                tot_w = tot_r = 0
                cells = []
                for name in probe.videos():
                    if truth_seq(name) is None:
                        continue  # только размеченные записи (см. run_all)
                    r = decide(name, half=half, gate=gate, gate_mode=mode)
                    tot_w += r["white_events"]
                    tot_r += r["red_events"]
                    cells.append("%d/%d" % (r["white_events"], r["red_events"]))
                print("half=%-3d mode=%-11s gate=%-4.1f  sum W=%-3d R=%-3d  %s"
                      % (half, mode or GATE_MODE, gate, tot_w, tot_r,
                         " ".join(cells)), flush=True)
    elif args and args[0] == "ablate":
        # Разрез трёх правок по человеческой разметке: каждая ОТДЕЛЬНО и все
        # вместе. Корпус поделён на «старые» (со штатива) и новые ручные: базовое
        # число 21 относится к первым, 54 — ко всем сразу, и путать их нельзя.
        gate = float(args[1]) if len(args) > 1 else 3.0
        only = next((a for a in args[2:] if not a.replace('.', '', 1).isdigit()),
                    None)
        variants = [
            ("исходная      ", {}),
            ("заморозка пола", {"freeze": True}),
            ("пол без чужой ", {"xcl": True}),
            ("пересвет=блок ", {"clipall": True}),
            ("яркость растёт", {"edge": True}),
            ("заморозка+блок", {"freeze": True, "clipall": True}),
            ("все три прежних", {"freeze": True, "xcl": True, "clipall": True}),
            ("фронт+три     ", {"freeze": True, "xcl": True, "clipall": True,
                               "edge": True}),
        ]
        for label, kw in variants:
            full = {"freeze": False, "xcl": False, "clipall": False,
                    "edge": False}
            full.update(kw)
            rows, err = run_all(only=only, gate=gate, **full)
            per = {}
            for p, s in rows:
                per[group_of(s["file"])] = per.get(group_of(s["file"]), 0) + p
            ex = sum(s["extra"] for _, s in rows)
            ms = sum(s["missed"] for _, s in rows)
            print("%s  gate=%.1f  ошибок=%-3d (%s)  лишних=%-3d пропущено=%-3d"
                  % (label, gate, err,
                     " ".join("%s=%d" % kv for kv in sorted(per.items())),
                     ex, ms), flush=True)
    elif args and args[0] == "truth":
        # Сверка с человеческой разметкой (TRUTH выше): сколько событий
        # сошлось, сколько модель добавила и сколько пропустила.
        gate = float(args[1]) if len(args) > 1 else 1.5
        mem = int(args[2]) if len(args) > 2 and args[2].isdigit() else 0
        only = next((a for a in args[2:] if not a.replace('.', '', 1).isdigit()),
                    None)
        rows, err = run_all(only=only, gate=gate, mem=mem)
        report(rows, err, "разметка: gate=%.1f mem=%d%s"
               % (gate, mem, " корпус=" + only if only else ""))
    elif args and args[0] == "fit":
        # Подбор по разметке: минимум (лишние + пропущенные) по сетке
        # «память вето × крутость вето».
        grid = []
        for mem in (0, 300, 500, 700, 1000, 1500):
            for gate in (1.0, 1.5, 2.0, 3.0):
                rows, err = run_all(gate=gate, mem=mem)
                grid.append((err, mem, gate, rows))
        for err, mem, gate, rows in sorted(grid, key=lambda x: (x[0], -x[2])):
            print("mem=%-5d gate=%-4.1f ошибок=%-3d  %s"
                  % (mem, gate, err,
                     " ".join("%s:%d+%d-%d" % (stamp(s["file"]), p,
                                               s["extra"], s["missed"])
                              for p, s in rows)), flush=True)
        best = min(grid, key=lambda x: (x[0], -x[2]))
        report(best[3], best[0], "лучшее (mem=%d, gate=%.1f):"
               % (best[1], best[2]))
    elif args and args[0] == "cmp":
        # Проверка совета «цвет смотреть не надо, главное — зафиксировать
        # вспышку»: ОДИН и тот же автомат (окно, пол, σ, вето, гистерезис),
        # разные носители решения — яркость против доли цветных пикселей.
        # Счёт по человеческой разметке, поэтому оба числа честные.
        for carrier in ('luma', 'hsv'):
            best = None
            for gate in (1.0, 1.5, 2.0, 3.0):
                for mem in (0, 300, 500, 700, 1000):
                    rises = (0.03, 0.06, 0.10) if carrier == 'luma' else (0.06,)
                    for min_rise in rises:
                        rows, err = run_all(gate=gate, mem=mem, gate_mode='cross-zone',
                                            min_rise=min_rise, carrier=carrier)
                        extra = sum(s["extra"] for _, s in rows)
                        missed = sum(s["missed"] for _, s in rows)
                        if best is None or (err, extra) < (best[0], best[1]):
                            best = (err, extra, missed, gate, mem, min_rise, rows)
            err, extra, missed, gate, mem, min_rise, rows = best
            print("носитель=%-5s: ошибок=%-3d (лишних=%-3d пропущено=%-3d) "
                  "при gate=%.1f mem=%d minRise=%.2f"
                  % (carrier, err, extra, missed, gate, mem, min_rise),
                  flush=True)
            report(rows, err, "  breakdown:")
    elif args and args[0] == "vmin":
        # Перебор НИЖНЕЙ границы яркости «красного» (probe.WARM_V_MIN). Кэш
        # рядов кладётся в отдельную папку на каждое значение: иначе старый кэш
        # молча вернул бы ряды, набранные с другим отбором.
        base = probe.OUT
        for vm in [float(x) for x in args[1:]] or [0.45, 0.55, 0.65]:
            probe.WARM_V_MIN = vm
            probe.OUT = os.path.join(base, "vmin_%03d" % int(vm * 100))
            os.makedirs(probe.OUT, exist_ok=True)
            tot_w = tot_r = 0
            cells = []
            for name in probe.videos():
                if truth_seq(name) is None:
                    continue  # только размеченные записи (см. run_all)
                r = decide(name, gate=1.5)
                tot_w += r["white_events"]
                tot_r += r["red_events"]
                cells.append("%d/%d" % (r["white_events"], r["red_events"]))
            print("WARM_V_MIN=%.2f gate=1.5 sum W=%-3d R=%-3d %s"
                  % (vm, tot_w, tot_r, " ".join(cells)), flush=True)
        probe.OUT = base
    elif args and args[0] == "events":
        # Разметка, независимая от автомата: что и где переключали.
        # Вердикт на эпизод: W = подъём cool больше подъёма warm; R = наоборот;
        # r_edge = warm больше, но яркость при этом ПАДАЕТ — то есть это не
        # красная лампа, а остаток на падающем фронте белой.
        rise, names = pick(args)
        for name in names:
            if stamp(name) not in MANUAL:
                continue
            eps = episodes(name, rise=rise)
            seq = ""
            print("== %s %s  (%d эпизодов)" % (stamp(name),
                  os.path.basename(name), len(eps)))
            for e in eps:
                cw, rw = max(e["L_cool"], e["R_cool"]), max(e["L_warm"], e["R_warm"])
                dv = max(e["L_dV"], e["R_dV"])
                if rw > cw and dv > 0.02:
                    c = 'R'
                elif rw > cw:
                    c = 'r'      # тёплый на падающей яркости = артефакт
                else:
                    c = 'W'
                seq += c
                print("   %6.2fс dur=%4.2f  L: dV%+.2f cool%+.2f warm%+.2f | "
                      "R: dV%+.2f cool%+.2f warm%+.2f  -> %s"
                      % (e["t_ms"] / 1000.0, e["dur"], e["L_dV"], e["L_cool"],
                         e["L_warm"], e["R_dV"], e["R_cool"], e["R_warm"], c),
                      flush=True)
            print("   лента: %s" % seq, flush=True)
    elif args and args[0] == "amb":
        # Тот же список эпизодов, но рядом — что в ЭТОТ МОМЕНТ сделалось со
        # ВСЕМ кадром и с дальним фоном. Гипотеза была: свет зала поднимает кадр
        # так же сильно, как зону, а лампа — зону заметно сильнее кадра.
        # ИЗМЕРЕНО (§35): верно только для белой лампы на Pixel; вето по этому
        # признаку в `decide()` не занесено. Режим оставлен как линейка — им
        # проверяют любой новый признак «это лампа или освещение комнаты».
        rise, names = pick(args)
        for name in names:
            if stamp(name) not in MANUAL:
                continue
            eps = episodes(name, rise=rise)
            aV, aC, aW, aF = ambient(name)
            n = len(aV)
            print("== %s  (%d эпизодов)" % (stamp(name), len(eps)), flush=True)
            for e in eps:
                i = int(e["t_ms"] * probe.FPS / 1000.0)
                k = min(n - 1, i + max(1, int(e["dur"] * probe.FPS / 2)))
                p = max(0, i - 15)
                dV = float(aV[k]) - float(np.median(aV[p:i + 1]))
                dF = float(aF[k]) - float(np.median(aF[p:i + 1]))
                own = max(e["L_cool"], e["L_warm"], e["R_cool"], e["R_warm"])
                zone = max(e["L_dV"], e["R_dV"])
                print("   %6.2fс own=%+.2f зона dV=%+.2f | кадр dV=%+.3f"
                      " дальний dV=%+.3f | зона/дальний=%s"
                      % (e["t_ms"] / 1000.0, own, zone, dV, dF,
                         "%.2f" % (zone / dF) if dF > 0.01 else ">>"),
                      flush=True)
    elif args and args[0] == "oracle":
        # «Какая лампа переключалась» доказывается ПОЗИЦИЕЙ рамки, а не цветом:
        # белая стоит слева, красная — справа (оранжевый колпак виден на листе
        # `lit`), и перетекание цвета на геометрию не влияет. Прогон тем же
        # автоматом, но носителем решения — яркость своей зоны
        # (carrier='luma'): его лента и есть ответ «что происходило в кадре».
        # Расхождение с цветной лентой = мера перетекания белого в «тёплый»
        # признак; совпадение позиции с диктовкой расшифровки = опора для
        # эталона, которого у нового корпуса ещё нет.
        gate = float(args[1]) if len(args) > 1 and re.match(r"[\d.]", args[1]) else 3.0
        only = next((a for a in args[1:] if not re.match(r"[\d.]", a)), None)
        if only == "new":
            names = probe.videos_of(probe.DIRS[1:])
        elif only:
            names = [n for n in probe.videos() if group_of(n) == only]
        else:
            names = probe.videos()
        for name in names:
            if stamp(name) not in MANUAL:
                continue   # без центров нечего называть «левая» и «правая»
            col = decide(name, gate=gate, carrier='hsv', min_rise=MIN_RISE,
                         gate_mode='cross-zone')
            pos = decide(name, gate=gate, carrier='luma', min_rise=0.05,
                         gate_mode='cross-zone')
            a, b = model_seq(col), model_seq(pos)
            print("%-9s цвет %-19s W%-2d R%-2d | позиция %-19s W%-2d R%-2d  %s"
                  % (stamp(name), a, col["white_events"], col["red_events"],
                     b, pos["white_events"], pos["red_events"],
                     "совпало" if a == b else ""), flush=True)
    elif args and args[0] == "calib":
        # Калибровка против догадки. Один и тот же автомат, два ответа на вопрос
        # «какой ряд доказывает включение»: историческая догадка (белая = cool
        # своей зоны, красная = warm своей) против измеренной по заведомо
        # известным состояниям лампы (`learn_selects`). Обучение leave-one-out:
        # для каждого клипа ряды выбираются по ДРУГИМ клипам его корпуса, чтобы
        # разметка одного клипа не отвечала на вопрос про него же.
        gate = next((float(a) for a in args[1:]
                     if re.fullmatch(r"[\d]*\.?\d+", a)), 3.0)
        words = [a for a in args[1:] if not re.fullmatch(r"[\d]*\.?\d+", a)]
        only = next((a for a in words if a == "new" or a in
                     {group_of(n) for n in probe.videos()}), None)
        scope = 'own-zone' if "own" in words else 'any'
        by_group = {}
        for name in probe.videos():
            if truth_seq(name) is None:
                continue
            g = group_of(name)
            if only == "new" and g == "стенд":
                continue
            if only and only != "new" and g != only:
                continue
            by_group.setdefault(g, []).append(name)
        grand = [0, 0]
        for g, names in sorted(by_group.items()):
            sel, ev = learn_selects(names, scope=scope)
            print("== %s  gate=%.1f  поиск=%s  (%d записей)"
                  % (g, gate, scope, len(names)), flush=True)
            print("   учится на: %s"
                  % (" ".join(ev["used"]) or "чистых клипов нет"), flush=True)
            for lab in "WR":
                print("   метка %s: %s" % (lab, "  ".join(
                    "зона%d/%s %s" % (r[0], r[1],
                                       "%+.3f" % ev["means"][lab][r]
                                       if ev["means"][lab][r] is not None
                                       else "—") for r in ROWS)), flush=True)
            print("   выбрано: белая = зона%d/%s, красная = зона%d/%s"
                  "   (догадка: зона%d/%s и зона%d/%s)"
                  % (sel[0][0], sel[0][1], sel[1][0], sel[1][1],
                     W_SEL[0], W_SEL[1], R_SEL[0], R_SEL[1]), flush=True)
            gb = ga = 0
            for name in names:
                s_loo, _ = learn_selects([n for n in names if n != name],
                                         scope=scope)
                sb = score(name, decide(name, gate=gate))
                sa = score(name, decide(name, gate=gate, w_sel=s_loo[0],
                                       r_sel=s_loo[1]))
                pb, pa = penalty(sb), penalty(sa)
                gb += pb
                ga += pa
                pure = len(set(sb["truth"])) == 1 and sb["truth"]
                print("   %-9s эталон %-11s | догадка %-11s err=%-3d"
                      " | калибр. %-11s err=%-3d  ряды W=%s R=%s %s"
                      % (stamp(name), sb["truth"], sb["model"], pb,
                         sa["model"], pa,
                         "%d/%s" % s_loo[0], "%d/%s" % s_loo[1],
                         "(учится на себе)" if pure else ""),
                      flush=True)
            print("   ИТОГО %s: догадка %d -> калибровка %d" % (g, gb, ga),
                  flush=True)
            grand[0] += gb
            grand[1] += ga
        print("ВСЕГО: догадка %d -> калибровка %d" % tuple(grand), flush=True)
    elif args and args[0] == "sign":
        # Событие без догадки, имя -- по выученной границе (`learn_boundary`).
        # Сравнение с действующим автоматом идёт в тех же строках и по тому же
        # эталону, поэтому оба числа честные. Обучение -- leave-one-out: для
        # каждого клипа граница строится по ДРУГИМ клипам его корпуса; если без
        # себя клип остаётся единственным состоянием (так бывает), помечается
        # «*на себе» и граница берётся с участием клипа.
        nums = [float(a) for a in args[1:] if re.fullmatch(r"[\d]*\.?\d+", a)]
        rise = nums[0] if nums else 0.08
        gate = nums[1] if len(nums) > 1 else 3.0
        words = [a for a in args[1:]
                 if not re.fullmatch(r"[\d]*\.?\d+", a)]
        only = next((a for a in words if a == "new" or a in
                     {group_of(n) for n in probe.videos()}), None)
        # «manual» оставляет только клипы с руками закреплёнными рамками
        # (MANUAL). Без этого фильтра проверка нечестная: там, где центры
        # найдены автоматически, зона 0 строится как «где больше cool», то есть
        # догадка о каналах уже вшита в нумерацию зон, и выучивать там нечего.
        manual_only = "manual" in words
        # «auto» меняет ТИП обнаружения: вместо эпизодов с фиксированным порогом
        # по всему клипу -- автомат со скользящим полом по агрегированному ряду
        # (`events_any`), то есть ровно та сборка, которая предлагается в модель:
        # обнаруживает автомат, называет выученная граница. Тогда `rise` становится
        # значением MIN_RISE этого автомата.
        auto = "auto" in words
        sigf = (lambda n: events_any(n, min_rise=rise)) if auto else None
        by_group = {}
        for name in probe.videos():
            if truth_seq(name) is None:
                continue
            if manual_only and stamp(name) not in MANUAL:
                continue
            g = group_of(name)
            if only == "new" and g == "стенд":
                continue
            if only and only != "new" and g != only:
                continue
            by_group.setdefault(g, []).append(name)
        grand = [0, 0]
        for g, names in sorted(by_group.items()):
            cls = learn_boundary(names, rise, sigf)
            print("== %s  rise=%.2f gate=%.1f  %s  (%d записей)"
                  % (g, rise, gate,
                     "обнаружение: автомат по max(4 рядов)"
                     if auto else "обнаружение: эпизоды по порогу",
                     len(names)), flush=True)
            if cls is None:
                print("   обоих состояний в этом корпусе нет -- называть нечем",
                      flush=True)
            else:
                print("   учится на: %s" % " ".join(cls["used"]), flush=True)
                print("   признак: %s, порог %.3f, «выше = %s», "
                      "средние W%+.3f/R%+.3f, чистота %.1f, ошибок при "
                      "обучении %d из %d"
                      % (feat_name(cls["feat"]), cls["thr"], cls["high"],
                         cls["means"][0], cls["means"][1], cls["sep"],
                         cls["train_err"], sum(cls["n"])), flush=True)
            tot = [0, 0]
            unnamed = 0
            for name in names:
                others = [n for n in names if n != name]
                c = learn_boundary(others, rise, sigf)
                self_taught = c is None
                if self_taught:
                    c = cls
                truth = truth_seq(name)
                pa = penalty(score(name, decide(name, gate=gate)))
                if c is None:
                    # Второго класса нет ни при каком leave-one-out, то есть
                    # граница не выучивается даже с участием самого клипа. Тогда
                    # называть нечем, и выдуманную ленту нельзя класть в сумму
                    # ошибок: §42, группа «pixel-стена» — там 145128 не даёт ни
                    # одного красного события, и клип давал бы 14 «ошибок» за
                    # то, чего в материале нет.
                    tot[0] += pa
                    unnamed += 1
                    print("   %-9s эталон %-11s | автомат err=%-3d | граница"
                          " не именуется: нет второго класса"
                          % (stamp(name), truth, pa), flush=True)
                    continue
                _, seq = tape(name, c, rise, sigf)
                ps = tape_err(truth, seq)
                tot[0] += pa
                tot[1] += ps
                print("   %-9s эталон %-11s | автомат err=%-3d | граница %-13s"
                      " err=%-3d%s"
                      % (stamp(name), truth, pa, seq, ps,
                         "  *на себе" if self_taught else ""), flush=True)
            print("   ИТОГО %s: автомат %d -> граница %d%s"
                  % (g, tot[0], tot[1],
                     "  (%d без имени не в счёт)" % unnamed if unnamed else ""),
                  flush=True)
            grand[0] += tot[0]
            grand[1] += tot[1]
        print("ВСЕГО: автомат %d -> граница %d" % tuple(grand), flush=True)
    else:
        if args and args[0] == "new":
            # Съёмка в офисе (папки 1 и 2 из probe.DIRS) — без ручного перечисления
            # имён в командной строке.
            names = probe.videos_of(probe.DIRS[1:])
        else:
            names = args if args else probe.videos()
        for name in names:
            try:
                print(json.dumps(decide(name), ensure_ascii=False))
            except Exception as e:  # noqa: BLE001
                print(json.dumps({"file": name, "error": str(e)[:200]}))
