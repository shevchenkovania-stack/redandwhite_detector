"""Проверка ГРАНИЦ HSV-отбора (не порогов отсчёта) по видео стенда.

Отвечает на четыре вопроса, которыми обоснованы числа в `LampConfig`:
  1. насколько узким может быть окно оттенка красной лампы (12/18/30/45/60°);
  2. где проходит граница «белый» по насыщенности (0.15 / 0.25 / 0.35) и по
     яркости (0.75 / 0.85 / 0.95);
  3. что стоят границы «красный» по яркости (0.45 / 0.55 / 0.65) и по
     насыщенности (0.35 / 0.45 / 0.55) — и на лампе, и на фоне;
  4. не выходит ли настоящий оттенок лампы за узкое «красное» окно.

Кадры «горит» берутся у самой модели (`hsv_decide.decide`, gate 1.5), поэтому
измеряем ровно те включения, которые детектор и считает. Фон — кадры без
включений плюс первая пятая часть записи до первого события.

Запуск:  python tools/hsv_bounds.py [имя_видео]
"""
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hsv_probe as probe  # noqa: E402
import hsv_decide as dec  # noqa: E402

HUES = (12.0, 18.0, 30.0, 45.0, 60.0)
SAT_MAXES = (0.15, 0.25, 0.35)
HALF = 24


def warm_mask(h, s, v, half_win, v_min=0.55, s_min=0.45):
    return ((h <= half_win) | (h >= 360.0 - half_win)) & (s >= s_min) & (v >= v_min)


def crop_to(f, cx, cy, idx):
    return np.stack([
        f[i, max(0, cy - HALF):cy + HALF, max(0, cx - HALF):cx + HALF] for i in idx])


def zone_rows(f, n, center, spans, kind):
    cx, cy = center
    lit = np.zeros(n, bool)
    for a, b in spans:
        if a is None:
            continue
        ia = int(round(a * probe.FPS / 1000.0))
        ib = n - 1 if b is None else int(round(b * probe.FPS / 1000.0))
        lit[ia:ib + 1] = True
    quiet = ~lit
    quiet[: max(1, n // 5)] = True
    row = {"zone": kind, "lit_frames": int(lit.sum())}
    if not lit.any():
        return row
    hl, sl, vl = probe.hsv(crop_to(f, cx, cy, np.flatnonzero(lit)))
    bg = crop_to(f, cx, cy, np.flatnonzero(quiet))[:60]
    hb, sb, vb = probe.hsv(bg)
    if kind == "warm":
        base = warm_mask(hl, sl, vl, 60.0)
        row["hue_p05_50_95"] = [round(float(x), 1) for x in
                                np.percentile(hl[base], [5, 50, 95])] if base.any() else None
        for w in HUES:
            m = warm_mask(hl, sl, vl, w)
            row["hue%d_px_per_frame" % int(w)] = round(float(m.sum()) / hl.shape[0], 1)
        mb = warm_mask(hb, sb, vb, 45.0)
        row["hue45_bg_px_per_frame"] = round(float(mb.sum()) / max(1, bg.shape[0]), 2)
        # Что режет нижняя граница яркости: доля пикселей оттенокного ядра с
        # V < 0.55 и площадь ядра при 0.45 / 0.55 / 0.65.
        core = (sl >= 0.45) & ((hl <= 45.0) | (hl >= 315.0))
        row["warm_V_below_055_frac"] = (
            round(float((core & (vl < 0.55)).sum()) / core.sum(), 3)
            if core.any() else None)
        for vm in (0.45, 0.55, 0.65):
            m = core & (vl >= vm)
            row["warm_v%.2f_px_per_frame" % vm] = round(float(m.sum()) / hl.shape[0], 1)
        # Цена границы насыщенности 0.45: площадь оттенкового ядра при
        # S >= 0.35 / 0.45 / 0.55 на яркой (V >= 0.55) части кадра.
        hue_core = ((hl <= 45.0) | (hl >= 315.0)) & (vl >= 0.55)
        for sm in (0.35, 0.45, 0.55):
            m = hue_core & (sl >= sm)
            row["warm_s%.2f_px_per_frame" % sm] = round(float(m.sum()) / hl.shape[0], 1)
        m_bg = ((hb <= 45.0) | (hb >= 315.0)) & (vb >= 0.55)
        row["warm_bg_s035_s045_s055_per_frame"] = [
            round(float((m_bg & (sb >= sm)).sum()) / max(1, bg.shape[0]), 1)
            for sm in (0.35, 0.45, 0.55)] if m_bg.any() else None
    else:
        for smax in SAT_MAXES:
            m = (vl >= 0.85) & (sl <= smax)
            row["cool_s%.2f_px_per_frame" % smax] = round(float(m.sum()) / sl.shape[0], 1)
        mb = (vb >= 0.85) & (sb <= 0.25)
        row["cool_s025_bg_px_per_frame"] = round(float(mb.sum()) / max(1, bg.shape[0]), 1)
        bright = vl >= 0.55
        row["S_p50_90_95_of_bright"] = ([round(float(x), 3) for x in
                                       np.percentile(sl[bright], [50, 90, 95])]
                                       if bright.any() else None)
        # Цена верхней границы яркости 0.85: площадь «почти без оттенка» при
        # 0.75 / 0.85 / 0.95.
        achromatic = sl <= 0.25
        for vm in (0.75, 0.85, 0.95):
            m = (vl >= vm) & achromatic
            row["cool_v%.2f_px_per_frame" % vm] = round(float(m.sum()) / sl.shape[0], 1)
    return row


def run(name):
    n, centers, _ = dec.build(name)
    res = dec.decide(name, gate=1.5)
    f = probe.frames(probe.path_of(name))
    rows = [
        zone_rows(f, n, centers[1], res["red_spans"], "warm"),
        zone_rows(f, n, centers[0], res["white_spans"], "cool"),
    ]
    print(json.dumps({"file": name, "rows": rows}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    args = sys.argv[1:]
    for nm in (args or probe.videos()):
        try:
            run(nm if nm.endswith(".mp4") else nm + ".mp4")
        except Exception as e:  # noqa: BLE001
            print(json.dumps({"file": nm, "error": str(e)[:200]}), flush=True)
