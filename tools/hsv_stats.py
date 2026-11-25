# -*- coding: utf-8 -*-
"""Числа HSV-модели по включениям, которые модель же и посчитала.

Что здесь нового против `hsv_probe.cmd_stats`:

* зоны берутся из кэшей `cache2_*_auto.npz`, то есть там же, где их находит
  `hsv_decide.lamp_centers` (перевес по РАЗНОСТИ признаков). Старый `cmd_stats`
  ищет «где больше cool / warm» и на пересвеченной стене садится мимо лампы —
  в старом `stats.jsonl` из-за этого центры `[0, 0]` и `[27, 0]`;
* события — те, что выдала сама модель (`hsv_decide.decide` при `GATE = 1.5`),
  а не куски «выше условных 0.15». Амплитуда мерится на этих же включениях;
* рядом с подъёмом цвета печатается подъём яркости `V p90` за те же включения —
  это ровно та величина, по которой решает режим живого отсчёта. Окно яркости
  набрано по кадрам ВНЕ горения (как в `live_reference.dart`), поэтому цифра не
  завышена исключением «горящих» кадров из «пола».

Запуск:  python tools/hsv_stats.py
"""
import io
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hsv_decide as dec  # noqa: E402
import hsv_probe as probe  # noqa: E402

GATE = 1.5            # принятое число модели (= LampConfig.hsvGate)
# Числа режима живого отсчёта — чтобы сравнивать цвет с яркостью по её правилам.
LIVE_SIGMAS, LIVE_MIN_RISE, LIVE_MAX_LEVEL = 6.0, 0.03, 0.15


def live_level(window):
    """Порог яркости как в `LiveReference._level`: 6σ, пол, потолок размаха."""
    hist = np.asarray(window)
    sigma = probe.robust_sigma(hist)
    span = float(np.percentile(hist, 95) - np.percentile(hist, 5))
    max_level = min(LIVE_MAX_LEVEL, max(LIVE_MIN_RISE, 0.5 * span))
    return min(max(LIVE_MIN_RISE, LIVE_SIGMAS * sigma), max_level)


def colour_rise(series):
    """Покадровый подъём своего цвета над «полом» скользящего окна — как в модели."""
    win = dec.Series()
    rises = []
    for v in series:
        win.add(float(v))
        if not win.ready:
            rises.append(None)
            continue
        rises.append(max(0.0, float(v) - win.floor))
    return rises


def frame_span(span, fps, n):
    on, off = span
    b = int(round((on or 0) / 1000.0 * fps))
    e = n if off is None else int(round(off / 1000.0 * fps))
    return max(0, min(b, n - 1)), max(b + 1, min(e, n))


def measure(name):
    """Статистика по одной записи: события модели + амплитуды на них."""
    dec.GATE = GATE
    r = dec.decide(name, gate=GATE)
    n, centers, z = dec.build(name)
    fps = probe.FPS
    rows = []
    for tag, zi, own_key, cross_key, spans, other_spans in (
        ("white/cool", 0, "cool", "warm", r["white_spans"], r["red_spans"]),
        ("red/warm", 1, "warm", "cool", r["red_spans"], r["white_spans"]),
    ):
        series = np.asarray(z[zi][own_key])
        cross = np.asarray(z[zi][cross_key])
        vv = np.asarray(z[zi]["V"])
        rises = colour_rise(series)
        # Всё, что модель не посчитала горением ни своей, ни чужой лампы, — фон,
        # из него же набирается и окно яркости.
        lit = np.zeros(n, bool)
        for sp in spans + other_spans:
            b, e = frame_span(sp, fps, n)
            lit[b:e] = True
        dark = series[~lit]
        v_dark = vv[~lit]
        v_floor = float(np.percentile(v_dark, 20)) if v_dark.size >= 5 else 0.0
        v_level = live_level(v_dark) if v_dark.size >= 5 else None
        own = []
        cross_on = []
        v_up = []
        # Шум СВОЕГО цвета по тёмной части — то, против чего работает пол
        # `MIN_RISE` и потолок `MAX_LEVEL` (в модели порог = min(max(minRise,
        # 6σ), потолок размаха)).
        c_sigma = probe.robust_sigma(dark) if dark.size >= 5 else 0.0
        c_floor = float(np.percentile(dark, 20)) if dark.size >= 5 else 0.0
        c_span = float(np.percentile(dark, 95) - np.percentile(dark, 5)) if dark.size >= 5 else 0.0
        c_max_level = min(dec.MAX_LEVEL, max(dec.MIN_RISE, 0.5 * c_span)) if c_span > 0 else dec.MAX_LEVEL
        c_level = min(max(dec.MIN_RISE, dec.SIGMAS * c_sigma), c_max_level)
        for sp in spans:
            b, e = frame_span(sp, fps, n)
            seg = [x for x in rises[b:e] if x is not None]
            own.append(max(seg) if seg else None)
            cross_on.append(float(np.max(cross[b:e] - np.percentile(cross, 20))))
            v_up.append(float(np.max(vv[b:e]) - v_floor))
        own = [x for x in own if x is not None]
        v_up = [x for x in v_up if x is not None]
        rows.append({
            "file": name, "zone": tag, "events": len(spans),
            "own_rise_min": round(min(own), 3) if own else None,
            "own_rise_med": round(float(np.median(own)), 3) if own else None,
            "own_rise_max": round(max(own), 3) if own else None,
            "cross_rise_max": round(max(cross_on), 3) if cross_on else None,
            "colour_level": round(c_level, 3),
            "colour_six_sigma": round(dec.SIGMAS * c_sigma, 3),
            "colour_floor_p20": round(c_floor, 3),
            "worst_over_level": round(min(own) / c_level, 2) if own and c_level else None,
            "V_rise_min": round(min(v_up), 3) if v_up else None,
            "V_rise_med": round(float(np.median(v_up)), 3) if v_up else None,
            "V_rise_max": round(max(v_up), 3) if v_up else None,
            "V_level": round(v_level, 3) if v_level is not None else None,
            "V_reaches_level": sum(1 for x in v_up if x > v_level) if v_level is not None else None,
            # Запас в разах: худшее событие / порог. Сравниваются ДВА способа на
            # одних и тех же включениях — цвет против яркости.
            "worst_V_over_level": round(min(v_up) / v_level, 2) if v_up and v_level else None,
        })
    return r, rows


def main():
    per_video, all_rows = [], []
    for name in probe.videos():
        r, rows = measure(name)
        tag = name.replace("PXL_20261123_", "").replace(".mp4", "")
        per_video.append({
            "id": tag, "W": r["white_events"], "R": r["red_events"],
            "own_min": min([x for x in (rows[0]["own_rise_min"], rows[1]["own_rise_min"]) if x is not None], default=None),
            "V_min": min([x for x in (rows[0]["V_rise_min"], rows[1]["V_rise_min"]) if x is not None], default=None),
        })
        all_rows += rows
    out = io.StringIO()
    for row in all_rows:
        out.write(json.dumps(row, ensure_ascii=False) + "\n")
    for v in per_video:
        out.write(json.dumps(v, ensure_ascii=False) + "\n")
    print(out.getvalue(), end="")
    with open(os.path.join(probe.OUT, "stats_model.jsonl"), "w", encoding="utf-8") as fh:
        fh.write(out.getvalue())

    def vals(key):
        return [r[key] for r in all_rows if r[key] is not None]

    total_events = sum(r["events"] for r in all_rows)
    print(json.dumps({
        "videos": len(per_video),
        "events_total": total_events,
        "own_rise": [min(vals("own_rise_min")), max(vals("own_rise_max"))],
        "own_rise_worst_median": sorted(vals("own_rise_med"))[:3],
        "colour_six_sigma": [min(vals("colour_six_sigma")), max(vals("colour_six_sigma"))],
        "colour_level": [min(vals("colour_level")), max(vals("colour_level"))],
        "cross_rise_max": [min(vals("cross_rise_max")), max(vals("cross_rise_max"))],
        "V_rise": [min(vals("V_rise_min")), max(vals("V_rise_max"))],
        "V_level": [min(vals("V_level")), max(vals("V_level"))],
        "V_reaches_level": f"{sum(vals('V_reaches_level'))}/{total_events}",
        # Запас худшего включения в разах против своего порога — у цвета и у
        # яркости; и где яркость не дотягивает.
        "worst_colour_margin": min((r["worst_over_level"], r["file"][13:22], r["zone"])
                                   for r in all_rows if r["worst_over_level"] is not None),
        "worst_V_margin": min((r["worst_V_over_level"], r["file"][13:22], r["zone"])
                              for r in all_rows if r["worst_V_over_level"] is not None),
        "V_misses": [(r["file"][13:22], r["zone"], r["events"] - r["V_reaches_level"])
                     for r in all_rows
                     if r["V_reaches_level"] is not None and r["V_reaches_level"] < r["events"]],
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
