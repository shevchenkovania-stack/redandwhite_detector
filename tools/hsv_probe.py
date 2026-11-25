"""Разбор стендовых видео для HSV-модели детекции ламп.

Видео лежат вне репозитория (папка стенда), всё, что пишет этот инструмент,
складывается в `%TEMP%/hsvlamp` — в дереве проекта не остаётся ничего.

Режимы:
  inventory                     — по каждому видео: распределения H/S/V и доли
                                  «белых»/«красных» пикселей (проверка, что HSV
                                  вообще различает лампы)
  model     <video> [fps]       — основная мерка: состояния кадра по долям
                                  цветных пикселей + ряды в двух зонах ламп
  all       [fps]               — `model` по всем видео в states.jsonl
  roi       <video>             — карты накопления белых/красных пикселей
  frames    <video>             — полоса из 6 кадров в PNG
  sheet                         — контактный лист по всем видео

Границы HSV нижние, их правят по числам из `model` (см. docs/ЖУРНАЛ.md).
"""
import json
import os
import subprocess
import sys

import numpy as np

DIR = r"C:\Users\isevcenco\Desktop\ред анд уайт\testvideo"
# Папки со съёмкой. Корпус ищется по всем: имена файлов в них не пересекаются
# (PXL_20261123_* / PXL_20261124_* / IMG_3395), так что один индекс по всем
# папкам остаётся однозначным, а разметка в `hsv_decide.TRUTH` адресуется именем
# файла. iPhone пишет .MOV, Pixel и старый корпус — .mp4.
DIRS = [
    DIR,
    r"C:\Users\isevcenco\Desktop\ред анд уайт\сьемка в офисе pixel",
    r"C:\Users\isevcenco\Desktop\ред анд уайт\сьемка в офисе iphone 13",
    # 25.11.2026: `original` — НЕ ещё один стенд с печатными колпаками, а
    # НАСТОЯЩЕЕ изделие: прозрачный сигнальный маячок и красный купол на одной
    # тёмной плите, снятые с руки вертикальным 720x1280 @ 30 к/с, h264, bt709
    # (не HEVC/HLG, то есть тонмаппинг здесь не нужен). Камера ходит, поэтому
    # накопленные карты пиков тут ненадёжны, а разметки нет вовсе: клип
    # участвует в `inventory`/`model`/`stats`, но не в счёте ошибок
    # (для него нет TRUTH).
    r"C:\Users\isevcenco\Desktop\ред анд уайт\original",
]
VIDEO_EXT = (".mp4", ".mov")
OUT = os.path.join(os.environ.get("TEMP", "."), "hsvlamp")
W, H = 640, 360
FPS = 15.0

# HDR. ВСЁ снятое на телефоне (и старый корпус, и новые папки) приходит как
# HEVC 10-bit, BT.2020, transfer HLG (`arib-std-b67`). Прямой конверт ffmpeg в
# rgb24 без tone-mapping оставляет HLG-кривую в кадре: яркие пики сжимаются
# иначе, чем у телефона, который отдаёт в приложение SDR bt709. Это значит, что
# абсолютные границы `V >= 0.85` и `V >= 0.55` офлайн меряются не по той же
# шкале, что на устройстве. Мерить обе шкалы можно флагом окружения
# LAMP_TONEMAP=1; по умолчанию выключено, чтобы старые числа (54 ошибки и
# границы HSV) остались сравнимы с самими собой.
TONEMAP = os.environ.get("LAMP_TONEMAP", "") == "1"
TONEMAP_VF = (
    "zscale=t=linear:npl=203,format=gbrpf32le,zscale=p=bt709,"
    "tonemap=tonemap=hable:desat=0,"
    "zscale=t=bt709:m=bt709:r=tv"
)
_HDR_CACHE = {}


def is_hdr(path):
    """True, если источник HLG/PQ. Результат кэшируется на процесс."""
    if path not in _HDR_CACHE:
        try:
            p = subprocess.run(
                ["ffprobe", "-v", "error", "-select_streams", "v:0",
                 "-show_entries", "stream=color_transfer",
                 "-of", "default=noprint_wrappers=1:nokey=1", path],
                capture_output=True, text=True, timeout=20)
            _HDR_CACHE[path] = p.stdout.strip() in ("arib-std-b67", "smpte2084")
        except Exception:  # noqa: BLE001
            _HDR_CACHE[path] = False
    return _HDR_CACHE[path]


def _index():
    idx = {}
    for d in DIRS:
        if not os.path.isdir(d):
            continue
        for f in sorted(os.listdir(d)):
            if f.lower().endswith(VIDEO_EXT):
                if f in idx:
                    raise RuntimeError(
                        "имя файла встречается в двух папках: %s" % f)
                idx[f] = os.path.join(d, f)
    return idx


PATHS = _index()


def path_of(name):
    """Полный путь видео по имени; старые вызовы с путем от DIR работают."""
    return PATHS.get(name, os.path.join(DIR, name))


def videos():
    return sorted(PATHS)

# Цветовые окна. Красная лампа на стенде светит оранжевым: медиана оттенка ядра
# красной зоны на посчитанных включениях 25.6..34.7° (`hsv_bounds.py`), поэтому
# окно WARM_H_LO обязано доставать до ~45°. Белая — тот же кадр, но с насыщением
# почти нулевым.
COOL_V_MIN = 0.85   # ярко
COOL_S_MAX = 0.25   # и без оттенка -> «белый»
WARM_V_MIN = 0.55   # тёплый, но не тёмное дерево стола
WARM_S_MIN = 0.45   # и заметно цветной
WARM_H_LO = 45.0    # градусы: окно вокруг нуля
WARM_H_HI = 315.0


def videos_of(dirs):
    """Только имена из перечисленных папок — для прогонов по одному источнику."""
    return [n for n in PATHS if any(os.path.normpath(os.path.dirname(PATHS[n]))
                                    == os.path.normpath(d) for d in dirs)]


def frames(path, fps=FPS, size=(W, H)):
    """Декод через ffmpeg в RGB24; (N,h,w,3) uint8.

    Для HDR-источников при LAMP_TONEMAP=1 перед масштабированием ставится
    tone-map HLG/PQ -> bt709, чтобы яркость кадра была в той же шкале, что и
    кадр, полученный с телефона.
    """
    sw, sh = size
    vf = "fps=%g," % fps
    if TONEMAP and is_hdr(path):
        vf += TONEMAP_VF + ","
    vf += "scale=%d:%d:flags=bilinear,format=rgb24" % (sw, sh)
    cmd = [
        "ffmpeg", "-v", "error", "-i", path,
        "-vf", vf,
        "-pix_fmt", "rgb24", "-f", "rawvideo", "-",
    ]
    p = subprocess.run(cmd, capture_output=True)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.decode("utf8", "ignore")[:300])
    buf = np.frombuffer(p.stdout, dtype=np.uint8)
    n = buf.size // (sw * sh * 3)
    return buf[: n * sw * sh * 3].reshape(n, sh, sw, 3)


def hsv(rgb):
    """Векторный RGB->HSV: H в градусах 0..360, S и V 0..1."""
    r = rgb[..., 0].astype(np.float32) / 255.0
    g = rgb[..., 1].astype(np.float32) / 255.0
    b = rgb[..., 2].astype(np.float32) / 255.0
    mx = np.maximum(np.maximum(r, g), b)
    mn = np.minimum(np.minimum(r, g), b)
    d = mx - mn
    h = np.zeros_like(mx)
    nz = d > 1e-6
    ir = nz & (mx == r)
    ig = nz & (mx == g) & ~ir
    ib = nz & ~ir & ~ig
    h[ir] = (60.0 * ((g[ir] - b[ir]) / d[ir]) + 360.0) % 360.0
    h[ig] = 60.0 * ((b[ig] - r[ig]) / d[ig]) + 120.0
    h[ib] = 60.0 * ((r[ib] - g[ib]) / d[ib]) + 240.0
    s = np.zeros_like(mx)
    np.divide(d, mx, out=s, where=mx > 1e-6)
    return h, s, mx


def cool_warm(h, s, v):
    """Две маски: «белый свет» и «красный свет»."""
    cool = (v >= COOL_V_MIN) & (s <= COOL_S_MAX)
    warm = (((h <= WARM_H_LO) | (h >= WARM_H_HI)) & (s >= WARM_S_MIN) & (v >= WARM_V_MIN))
    return cool, warm


def box(a, k=25):
    """Среднее в окне k x k (нечётное) через интегральную картинку; размер не меняется."""
    pad = k // 2
    p = np.pad(a.astype(np.float64), pad, mode="edge")
    c = np.zeros((p.shape[0] + 1, p.shape[1] + 1))
    c[1:, 1:] = p.cumsum(0).cumsum(1)
    return (c[k:, k:] - c[:-k, k:] - c[k:, :-k] + c[:-k, :-k]) / (k * k)


def peak(a, block=80, margin=0):
    """Два неперекрывающихся пика: (x, y, значение, x2, y2, значение2).

    `margin` срезаёт кайму кадра перед поиском: в офисной съёмке верхняя строка
    перебита в белый (cool = 1.0 при y = 0), и без отступа пик «холодных»
    уезжает на потолок вместо лампы. То же самое уже ловили на ручных записях
    старого корпуса (`cool` пик на (71,359) при высоте 360).
    """
    if margin:
        a = a.copy()
        a[:margin, :] = -1
        a[-margin:, :] = -1
        a[:, :margin] = -1
        a[:, -margin:] = -1
    y, x = np.unravel_index(np.argmax(a), a.shape)
    b = a.copy()
    b[max(0, y - block): y + block, max(0, x - block): x + block] = -1
    y2, x2 = np.unravel_index(np.argmax(b), b.shape)
    return (int(x), int(y), float(a[y, x]), int(x2), int(y2), float(b[y2, x2]))


def series_in(f, x, y, half=24):
    """Ряды признаков одной зоны: доля белых, доля красных, p90 яркости."""
    out = {"cool": [], "warm": [], "V": []}
    for i in range(f.shape[0]):
        crop = f[i, max(0, y - half): y + half, max(0, x - half): x + half]
        h, s, v = hsv(crop)
        c, w = cool_warm(h, s, v)
        out["cool"].append(float(c.mean()))
        out["warm"].append(float(w.mean()))
        out["V"].append(float(np.percentile(v, 90)))
    return {k: np.asarray(v) for k, v in out.items()}


def segments(flags, gap=2):
    """Начала кусков «истина», склеенные, если разрыв не больше gap кадров."""
    idx = np.flatnonzero(np.diff(flags.astype(np.int8)) == 1)
    if flags[0]:
        idx = np.r_[0, idx]
    keep = []
    for i in idx:
        if not keep or i - keep[-1] > gap:
            keep.append(int(i))
    return keep


def cmd_model(name, fps=FPS):
    """Главная мерка: состояния кадра по цветовым долям + ряды в зонах ламп."""
    f = frames(path_of(name), fps=fps)
    n = f.shape[0]
    cool_map = np.zeros((H, W), np.float32)
    warm_map = np.zeros((H, W), np.float32)
    gc = np.zeros(n)
    gw = np.zeros(n)
    for i in range(n):
        h, s, v = hsv(f[i])
        c, w = cool_warm(h, s, v)
        cool_map += c
        warm_map += w
        gc[i] = c.mean()
        gw[i] = w.mean()
    # Зоны ламп ищем по тому, где за видео накопилось больше всего цветных пикселей:
    # белая — где «cool», красная — где «warm».
    pc = peak(box(cool_map, 25))
    pw = peak(box(warm_map, 25))
    centers = [(pc[0], pc[1]), (pw[0], pw[1])]
    z = [series_in(f, x, y) for (x, y) in centers]
    tc = max(float(np.percentile(gc, 50)) + 0.01, 0.02)
    tw = max(float(np.percentile(gw, 50)) + 0.01, 0.02)
    state = np.where((gc > tc) & (gw > tw), 3, np.where(gw > tw, 2, np.where(gc > tc, 1, 0)))
    names = {0: "off", 1: "white", 2: "red", 3: "both"}
    print(json.dumps({
        "file": name, "fps": fps, "frames": n,
        "whiteZone": centers[0], "redZone": centers[1],
        "cool_thr": round(tc, 3), "warm_thr": round(tw, 3),
        "frames_by_state": {names[k]: int((state == k).sum()) for k in range(4)},
        "events_white": len(segments((state == 1) | (state == 3))),
        "events_red": len(segments((state == 2) | (state == 3))),
        "zoneCool_p50_on_off": [round(float(np.median(z[0]["cool"][state == 1])), 3),
                                 round(float(np.median(z[0]["cool"][state == 0])), 3)],
        "zoneWarm_p50_on_off": [round(float(np.median(z[1]["warm"][state == 2])), 3),
                                round(float(np.median(z[1]["warm"][state == 0])), 3)],
        "zoneV_p50_on_off": [round(float(np.median(z[0]["V"][state == 1])), 3),
                             round(float(np.median(z[0]["V"][state == 0])), 3)],
    }, ensure_ascii=False))
    b = 0
    for i in range(1, n + 1):
        if i == n or state[i] != state[b]:
            if i - b >= 3:
                k = state[b]
                print(json.dumps({
                    "t_ms": round(b * 1000 / fps), "dur_ms": round((i - b) * 1000 / fps),
                    "state": names[k],
                    "cool": round(float(gc[b:i].mean()), 3),
                    "warm": round(float(gw[b:i].mean()), 3),
                    "wz_cool": round(float(z[0]["cool"][b:i].mean()), 3),
                    "wz_warm": round(float(z[0]["warm"][b:i].mean()), 3),
                    "wz_V": round(float(z[0]["V"][b:i].mean()), 3),
                    "rz_cool": round(float(z[1]["cool"][b:i].mean()), 3),
                    "rz_warm": round(float(z[1]["warm"][b:i].mean()), 3),
                    "rz_V": round(float(z[1]["V"][b:i].mean()), 3),
                }))
            b = i


def robust_sigma(x):
    """σ по MAD: вспышки внутри выборки не должны раздувать оценку шума."""
    if x.size < 3:
        return 0.0
    med = float(np.median(x))
    return 1.4826 * float(np.median(np.abs(x - med)))


def cmd_stats(name, fps=FPS, rise=0.15):
    """Запас канала: шум фона против минимального подъёма настоящей вспышки.

    Для каждой зоны берётся «свой» признак (белой зоне — доля cool, красной —
    доля warm) и «чужой». Событием считается кусок, где свой признак поднялся
    над 20-м процентилем окна на `rise`. Печатаем худший подъём, шум и то,
    насколько чужой признак поднимался в те же моменты (перетекание).
    """
    f = frames(path_of(name), fps=fps)
    n = f.shape[0]
    cool_map = np.zeros((H, W), np.float32)
    warm_map = np.zeros((H, W), np.float32)
    for i in range(n):
        h, s, v = hsv(f[i])
        c, w = cool_warm(h, s, v)
        cool_map += c
        warm_map += w
    pc = peak(box(cool_map, 25))
    pw = peak(box(warm_map, 25))
    zones = [("whiteZone", (pc[0], pc[1]), "cool"), ("redZone", (pw[0], pw[1]), "warm")]
    rows = []
    for label, (cx, cy), own in zones:
        s = series_in(f, cx, cy)
        series = s["cool"] if own == "cool" else s["warm"]
        cross = s["warm"] if own == "cool" else s["cool"]
        floor = float(np.percentile(series, 20))
        on = series > floor + rise
        pieces = []
        b = None
        for i in range(n):
            if on[i] and b is None:
                b = i
            elif not on[i] and b is not None:
                pieces.append([b, i])
                b = None
        if b is not None:
            pieces.append([b, n])
        # Куски, разнесённые меньше чем на 3 кадра, — это одно событие, а не два:
        # кадр может провалиться из-за потери или смаза.
        merged = []
        for p in pieces:
            if merged and p[0] - merged[-1][1] <= 3:
                merged[-1][1] = p[1]
            else:
                merged.append(p)
        amps = []
        cross_amps = []
        cross_floor = float(np.percentile(cross, 20))
        for b, e in merged:
            amps.append(float(series[b:e].max() - floor))
            cross_amps.append(float(cross[b:e].max() - cross_floor))
        quiet = series[~on]
        row = {
            "file": name, "zone": label, "center": [cx, cy], "own": own,
            "floor_p20": round(floor, 3),
            "off_p95": round(float(np.percentile(quiet, 95)) if quiet.size else 0, 3),
            "noise_sigma": round(robust_sigma(quiet), 4),
            "events": len(amps),
            "rise_min": round(min(amps), 3) if amps else None,
            "rise_med": round(float(np.median(amps)), 3) if amps else None,
            "rise_max": round(max(amps), 3) if amps else None,
            "cross_rise_max": round(max(cross_amps), 3) if cross_amps else None,
        }
        if amps and row["noise_sigma"]:
            row["min_over_6sigma"] = round(row["rise_min"] / (6 * row["noise_sigma"]), 2)
        rows.append(row)
        print(json.dumps(row, ensure_ascii=False))
    return rows


def cmd_all(fps=FPS):
    for name in videos():
        try:
            cmd_model(name, fps)
        except Exception as e:  # noqa: BLE001
            print(json.dumps({"file": name, "error": str(e)[:200]}))


def cmd_inventory():
    for name in videos():
        f = frames(path_of(name), fps=10.0)
        h = s = v = None
        wpx = rpx = 0
        hs = []
        for i in range(f.shape[0]):
            h, s, v = hsv(f[i])
            c, w = cool_warm(h, s, v)
            wpx += int(c.sum())
            rpx += int(w.sum())
            bright = v > 0.6
            if bright.sum() > 100:
                hs.append(np.histogram(h[bright], bins=np.arange(0, 361, 30))[0])
        hs = np.sum(np.stack(hs), axis=0)
        print(json.dumps({
            "file": name, "frames": int(f.shape[0]),
            "S_p50_p90_of_bright": [round(float(np.percentile(s[v > 0.6], 50)), 3),
                                    round(float(np.percentile(s[v > 0.6], 90)), 3)],
            "V_p50_p95": [round(float(np.percentile(v, 50)), 3), round(float(np.percentile(v, 95)), 3)],
            "cool_px_per_frame": round(wpx / f.shape[0], 1),
            "warm_px_per_frame": round(rpx / f.shape[0], 1),
            "hist30deg": (hs // max(1, f.shape[0])).tolist(),
        }, ensure_ascii=False))


def cmd_lampspot(name, fps=5.0, step=4):
    """Где мигает лампа: пик корреляции каждого пикселя с суммой «холодных»
    («тёплых») пикселей по кадру.

    Накопленная карта (`roi`) тут не работает: верхняя кайма офиса перебита в
    белый насквозь, и пик `cool` = 1.0 сидит на потолке; рука оператора даёт
    пик по дисперсии. Мигает только лампа, поэтому ищем не «где ярче», а «где
    значение растёт вместе с вспышками кадра». Пиксели считаются на карте
    `W/step x H/step`, координаты возвращаются в рабочих 640x360.
    """
    f = frames(path_of(name), fps=fps)
    n = f.shape[0]
    hh, ww = H // step, W // step
    cool = np.zeros((n, hh, ww), np.float32)
    warm = np.zeros((n, hh, ww), np.float32)
    for i in range(n):
        h, s, v = hsv(f[i])
        c, w = cool_warm(h, s, v)
        cool[i] = c.reshape(H, W)[: hh * step, : ww * step].reshape(hh, step, ww, step).mean((1, 3))
        warm[i] = w.reshape(H, W)[: hh * step, : ww * step].reshape(hh, step, ww, step).mean((1, 3))
    out = {}
    for tag, m in (("cool", cool), ("warm", warm)):
        ser = m.sum(axis=(1, 2))
        s0 = ser - ser.mean()
        corr = np.einsum("n,nhw->hw", s0, m - m.mean(0))
        corr /= max(1e-9, np.abs(s0).sum())
        p = peak(box(np.pad(corr, 2, mode="edge"), 5)[2:-2, 2:-2],
                 block=80 // step, margin=12 // step)
        out[tag] = [p[0] * step, p[1] * step, round(p[2], 5),
                    p[3] * step, p[4] * step, round(p[5], 5)]

    def flashes(a):
        """Счёт вспышек ряда по всему кадру: подъём > mean+3σ, рефрактер 250 мс.

        Нужен для опознания клипов: где физически стоит лампа по всему кадру
        не важно, а число белых и красных вспышек — это подпись, по которой
        файл сверяется со строкой плана.
        """
        thr = a.mean() + 3 * a.std()
        cnt, last = 0, -1e9
        for i, x in enumerate(a):
            t = 1000.0 * i / fps
            if x > thr and t - last > 250.0:
                cnt += 1
                last = t
        return cnt

    out["n_cool"] = flashes(cool.sum(axis=(1, 2)))
    out["n_warm"] = flashes(warm.sum(axis=(1, 2)))
    print(json.dumps({"file": name, "frames": int(n), **out}, ensure_ascii=False))


def cmd_roi(name):
    var = np.zeros((H, W))
    f = frames(path_of(name), fps=5.0)
    cool_map = np.zeros((H, W), np.float32)
    warm_map = np.zeros((H, W), np.float32)
    vsum = np.zeros((H, W))
    vsq = np.zeros((H, W))
    for i in range(f.shape[0]):
        h, s, v = hsv(f[i])
        c, w = cool_warm(h, s, v)
        cool_map += c
        warm_map += w
        vsum += v
        vsq += v * v
    var = np.maximum(vsq / f.shape[0] - (vsum / f.shape[0]) ** 2, 0)
    print(json.dumps({
        "file": name,
        "cool": peak(box(cool_map / f.shape[0], 25), margin=12),
        "warm": peak(box(warm_map / f.shape[0], 25), margin=12),
        "var": peak(box(var, 25), margin=12),
    }, ensure_ascii=False))
    import PIL.Image as Image
    strip = np.concatenate([(var * 4).clip(0, 1), cool_map / f.shape[0], warm_map / f.shape[0]], axis=1)
    Image.fromarray((strip * 255).astype(np.uint8)).save(os.path.join(OUT, name[:19] + "_maps.png"))


def cmd_sheet(count=3, thumb=(320, 180)):
    """Контактный лист: по `count` кадров из каждого видео, чтобы увидеть, что снимали."""
    import PIL.Image as Image
    rows = []
    for name in videos():
        f = frames(path_of(name), fps=10.0)
        idx = np.linspace(0, f.shape[0] - 1, min(count, f.shape[0])).astype(int)
        rows.append(np.concatenate(
            [np.asarray(Image.fromarray(f[i]).resize(thumb)) for i in idx], axis=1))
    sheet = np.concatenate(rows, axis=0)
    out = os.path.join(OUT, "sheet.png")
    Image.fromarray(sheet).save(out)
    print(out, sheet.shape)


def seek_frame(path, t_ms, size=(W, H)):
    """Один кадр по времени через быстрый seek (-ss до -i), без полного декода.

    Нужен потому, что выбирать центры зон по кадру иначе нельзя, а полный декод
    всего ролика ради трёх кадров стоит минуты. Кадр приводится к (W, H).
    """
    sw, sh = size
    cmd = [
        "ffmpeg", "-v", "error", "-ss", "%.3f" % (t_ms / 1000.0), "-i", path,
        "-frames:v", "1", "-vf", "scale=%d:%d:flags=bilinear" % (sw, sh),
        "-pix_fmt", "rgb24", "-f", "rawvideo", "-",
    ]
    p = subprocess.run(cmd, capture_output=True)
    if p.returncode != 0 or len(p.stdout) < sw * sh * 3:
        raise RuntimeError((p.stderr.decode("utf8", "ignore") or "пусто")[:200])
    return np.frombuffer(p.stdout[: sw * sh * 3], dtype=np.uint8).reshape(sh, sw, 3)


def grid(rgb, step=25, scale=2.0, label=True):
    """Сетка координат поверх кадра; подписи — в координатах 640x360.

    Рисуется ПОСЛЕ уменьшения в палец, иначе подписи не прочитать: `scale` —
    во сколько раз картинка меньше рабочих 640x360.
    """
    a = rgb.copy()
    h, w, _ = a.shape
    for x in range(0, w, step):
        a[:, max(0, x - 1):x + 1] = (0, 255, 0)
    for y in range(0, h, step):
        a[max(0, y - 1):y + 1, :] = (0, 255, 0)
    if label:
        import PIL.Image as Image
        import PIL.ImageDraw as ImageDraw
        img = Image.fromarray(a)
        d = ImageDraw.Draw(img)
        for x in range(0, w, step * 4):
            for y in range(step * 2, h, step * 4):
                d.text((x + 2, y - 5), "%d,%d" % (int(x * scale), int(y * scale)),
                       fill=(255, 255, 0))
        a = np.asarray(img)
    return a


def cmd_montage(arg="all", times=(3000, 8000, 14000), cols=3, thumb=(320, 180)):
    """Лист кадров с сеткой: по каждому видео из папки — кадры в `times`.

    Быстрый seek, полный декод не делается. Лист нужен, чтобы руками ставить
    центры зон (`MANUAL` в `hsv_decide.py`) там, где автопоиск по пикам бьёт
    мимо: в офисной съёмке верхняя кайма кадра перебита в белый (cool=1.0 при
    y=0), и пик «холодных» уезжает на потолок, а не на лампу.
    """
    import PIL.Image as Image
    if arg == "all":
        names, tag = videos(), "all"
    elif arg.isdigit() and int(arg) < len(DIRS):
        names, tag = videos_of([DIRS[int(arg)]]), "dir%s" % arg
    else:
        names, tag = [arg], arg[:12]
    rows = []
    for name in names:
        tiles = []
        for t in times:
            try:
                f = seek_frame(path_of(name), t)
            except Exception as e:  # noqa: BLE001
                print("%s @%d: %s" % (name, t, str(e)[:120]))
                f = np.zeros((H, W, 3), np.uint8)
            small = np.asarray(Image.fromarray(f).resize(thumb))
            tiles.append(grid(small, step=thumb[0] // 13, scale=W / thumb[0]))
        while len(tiles) < cols:
            tiles.append(np.zeros_like(tiles[0]))
        rows.append(np.concatenate(tiles, axis=1))
    out = os.path.join(OUT, "montage_%s.png" % tag)
    Image.fromarray(np.concatenate(rows, axis=0)).save(out)
    print(out, "строк=%d, ряды по порядку %s" % (len(rows), names),
          "кадры в мс: %s" % (list(times),))


def cmd_lampfind(name, fps=5.0):
    """Где стоят лампы и какого они цвета — по РАЗНИЦЕ яркого и тёмного кадра.

    Уровень не работает: в офисной съёмке стена над полкой перебита в белый от
    края до края (`cool` = 1.0 на всей полосе y < 54), поэтому и пик накопления,
    и пик корреляции садятся на стену. Мигает только лампа, поэтому ищем пик
    разности V(самый цветной кадр) - V(самый тёмный кадр) и для каждого пика
    считаем медиану H/S/V в окне вокруг него: по ней видно, белая это лампа
    (S мало) или красная (оттенок у нуля, S большое).
    """
    f = frames(path_of(name), fps=fps)
    n = f.shape[0]
    hv = []
    for i in range(n):
        h, s, v = hsv(f[i])
        c, w = cool_warm(h, s, v)
        hv.append((float(c.sum()) + float(w.sum()), v))
    bi = int(np.argmax([x[0] for x in hv]))
    b0 = int(np.argmin([x[0] for x in hv]))
    d = (hv[bi][1] - hv[b0][1]).clip(0)
    hh, ss, vv = hsv(f[bi])
    out = []
    a = box(d, 9)
    for _ in range(2):
        y, x = np.unravel_index(np.argmax(a), a.shape)
        if a[y, x] <= 0.01:
            break
        win = (slice(max(0, y - 24), y + 24), slice(max(0, x - 24), x + 24))
        sel = d[win] > 0.15
        out.append([
            int(x), int(y), round(float(a[y, x]), 3),
            round(float(np.median(hh[win][sel])), 1) if sel.any() else None,
            round(float(np.median(ss[win][sel])), 3) if sel.any() else None,
            round(float(np.median(vv[win][sel])), 3) if sel.any() else None,
            int(sel.sum()),
        ])
        a[max(0, y - 60): y + 60, max(0, x - 60): x + 60] = -1
    print(json.dumps({"file": name, "frames": int(n),
                      "lit_s": round(bi / fps, 1), "dark_s": round(b0 / fps, 1),
                      "lamps": out}, ensure_ascii=False))


def cmd_lit(arg="1", thumb=(640, 360), cols=3):
    """Лист по ОДНОМУ кадру на клип: момент, когда сумма «холодных» и
    «тёплых» пикселей по кадру максимальна, то есть лампа точно горит.

    Нужен для ручной наводки центров в новом корпусе: автопоиск по пикам
    накопления садит рамку на перебитый потолок, корреляция по пикселям
    показывает засветку на стене, а счётчик вспышек по всему кадру ловит
    движение камеры вместо лампы (проверено: 0..7 вместо 8 и 12).
    """
    import PIL.Image as Image
    if arg.isdigit() and int(arg) < len(DIRS):
        names, tag = videos_of([DIRS[int(arg)]]), "dir%s" % arg
    else:
        names, tag = [arg], arg[:12]
    rows = []
    for name in names:
        f = frames(path_of(name), fps=5.0)
        best, bi, bf = -1.0, 0, None
        for i in range(f.shape[0]):
            h, s, v = hsv(f[i])
            c, w = cool_warm(h, s, v)
            val = float(c.sum()) + float(w.sum())
            if val > best:
                best, bi, bf = val, i, (c.copy(), w.copy())
        # Центр лампы на этом кадре = самый плотный сгусток цвета, с отрезанной
        # верхней каймой (она перебита) и краями кадра.
        c, w = bf
        for m in (c, w):
            m[:40, :] = False
            m[-20:, :] = False
            m[:, :20] = False
            m[:, -20:] = False
        pc = peak(box(c, 15), block=60, margin=8)
        pw = peak(box(w, 15), block=60, margin=8)
        print("%s  кадр %d (%.1f с), цветных %d  cool(%d,%d)=%.3f  warm(%d,%d)=%.3f"
              % (name, bi, bi / 5.0, int(best), pc[0], pc[1], pc[2],
                 pw[0], pw[1], pw[2]), flush=True)
        small = np.asarray(Image.fromarray(f[bi]).resize(thumb))
        rows.append(grid(small, step=thumb[0] // 13, scale=W / thumb[0]))
    while len(rows) % cols:
        rows.append(np.zeros_like(rows[0]))
    tiles = [np.concatenate(rows[i: i + cols], axis=1)
             for i in range(0, len(rows), cols)]
    out = os.path.join(OUT, "lit_%s.png" % tag)
    Image.fromarray(np.concatenate(tiles, axis=0)).save(out)
    print(out, "кадры по порядку: %s" % names)


def cmd_frames(name, count=6):
    f = frames(path_of(name))
    idx = np.linspace(0, f.shape[0] - 1, min(count, f.shape[0])).astype(int)
    import PIL.Image as Image
    Image.fromarray(np.concatenate([f[i] for i in idx], axis=1)).save(
        os.path.join(OUT, name[:19] + "_strip.png"))
    print(os.path.join(OUT, name[:19] + "_strip.png"), [int(i) for i in idx])


def cmd_film(name, x, y, times_ms, half=40, scale=3):
    """Плёнка зоны: вырезка вокруг (x, y) в указанные моменты времени.

    Нужен, чтобы спорить не с цифрами, а с кадром: сомневаешься, было ли
    включение — смотришь полоску.
    """
    import PIL.Image as Image
    f = frames(path_of(name))
    tiles = []
    for t in times_ms:
        i = int(round(t / 1000.0 * FPS))
        i = max(0, min(f.shape[0] - 1, i))
        crop = f[i, max(0, y - half): y + half, max(0, x - half): x + half]
        img = Image.fromarray(crop).resize(
            (crop.shape[1] * scale, crop.shape[0] * scale), Image.NEAREST)
        tiles.append(np.asarray(img))
    out = os.path.join(OUT, name[:19] + "_film.png")
    Image.fromarray(np.concatenate(tiles, axis=1)).save(out)
    print(out, [int(round(t / 1000.0 * FPS)) for t in times_ms])


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    mode = sys.argv[1]
    if mode == "inventory":
        cmd_inventory()
    elif mode == "model":
        cmd_model(sys.argv[2], float(sys.argv[3]) if len(sys.argv) > 3 else FPS)
    elif mode == "all":
        cmd_all(float(sys.argv[2]) if len(sys.argv) > 2 else FPS)
    elif mode == "stats":
        if sys.argv[2] == "all":
            for v in videos():
                try:
                    cmd_stats(v)
                except Exception as e:  # noqa: BLE001
                    print(json.dumps({"file": v, "error": str(e)[:200]}))
        else:
            cmd_stats(sys.argv[2])
    elif mode == "spot":
        arg = sys.argv[2] if len(sys.argv) > 2 else "all"
        if arg == "all":
            names = videos()
        elif arg.isdigit() and int(arg) < len(DIRS):
            names = videos_of([DIRS[int(arg)]])
        else:
            names = [arg]
        for v in names:
            try:
                cmd_lampspot(v)
            except Exception as e:  # noqa: BLE001
                print(json.dumps({"file": v, "error": str(e)[:200]}))
    elif mode == "roi":
        # `roi <файл>` | `roi all` | `roi N` (номер папки из DIRS: 0 стенд,
        # 1 pixel, 2 iphone). Пики дают центры зон без ручной наводки по кадру.
        arg = sys.argv[2] if len(sys.argv) > 2 else "all"
        if arg == "all":
            names = videos()
        elif arg.isdigit() and int(arg) < len(DIRS):
            names = videos_of([DIRS[int(arg)]])
        else:
            names = [arg]
        for v in names:
            try:
                cmd_roi(v)
            except Exception as e:  # noqa: BLE001
                print(json.dumps({"file": v, "error": str(e)[:200]}))
    elif mode == "sheet":
        cmd_sheet()
    elif mode == "montage":
        cmd_montage(sys.argv[2] if len(sys.argv) > 2 else "all",
                    tuple(float(x) for x in sys.argv[3].split(","))
                    if len(sys.argv) > 3 else (3000, 8000, 14000))
    elif mode == "lit":
        cmd_lit(sys.argv[2] if len(sys.argv) > 2 else "1")
    elif mode == "lamps":
        arg = sys.argv[2] if len(sys.argv) > 2 else "all"
        if arg == "all":
            names = videos()
        elif arg.isdigit() and int(arg) < len(DIRS):
            names = videos_of([DIRS[int(arg)]])
        else:
            names = [arg]
        for v in names:
            try:
                cmd_lampfind(v)
            except Exception as e:  # noqa: BLE001
                print(json.dumps({"file": v, "error": str(e)[:200]}))
    elif mode == "frames":
        cmd_frames(sys.argv[2])
    elif mode == "film":
        cmd_film(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]),
                 [float(t) for t in sys.argv[5].split(",")])
    else:
        print(__doc__)
