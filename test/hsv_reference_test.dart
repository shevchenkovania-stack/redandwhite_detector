import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_detection/lamp_detection.dart';

int _ids = 0;
String _nextId() => 'hsv-${++_ids}';

/// Зона колпака в единицах HSV-отсчёта: доли «белых» и «красных» пикселей и
/// яркость p90 (она нужна только стопу на потолке сенсора).
FrameFeatures _zone({
  double cool = 0.02,
  double warm = 0.01,
  double v = 0.05,
}) => FrameFeatures(
  meanY: 255 * v,
  p90Luma: 255 * v,
  sampleCount: 400,
  coolFrac: cool,
  warmFrac: warm,
);

/// Стенд в HSV-единицах: белая вспышка поднимает `cool` белой зоны, красная —
/// `warm` красной. Ореолы не подаются вовсе: этот способ решает по одной зоне.
class _HsvBench {
  _HsvBench({LampConfig? config})
    : detector = LampDetector(
        config ?? const LampConfig(hsvReference: true, liveReference: false),
      ) {
    detector.resetTracking();
  }

  final LampDetector detector;
  final HitStateMachine machine = HitStateMachine(
    sessionId: 'hsv',
    idGenerator: _nextId,
  );
  final List<HitEvent> events = <HitEvent>[];
  LampEvaluation? last;
  int _frame = 0;

  /// Один кадр: доли своей и чужой зоны плюс яркость обеих.
  List<HitEvent> feed({
    double whiteCool = 0.02,
    double whiteWarm = 0.01,
    double whiteV = 0.05,
    double redWarm = 0.01,
    double redCool = 0.02,
    double redV = 0.05,
  }) {
    final int index = _frame++;
    final LampEvaluation evaluation = detector.evaluate(
      LampFrame(
        timestamp: DateTime.fromMillisecondsSinceEpoch(1000 + index * 100),
        white: _zone(cool: whiteCool, warm: whiteWarm, v: whiteV),
        red: _zone(cool: redCool, warm: redWarm, v: redV),
      ),
    );
    last = evaluation;
    final List<HitEvent> produced = machine.onEvaluation(evaluation);
    events.addAll(produced);
    return produced;
  }

  /// Окно «пола» набирается из тёмных кадров: 12 кадров при окне в 20.
  void warmup([int frames = 12]) {
    for (int i = 0; i < frames; i++) {
      feed();
    }
  }

  int get whiteHits => events.where((HitEvent e) => e.color == HitColor.white).length;
  int get redHits => events.where((HitEvent e) => e.color == HitColor.red).length;
}

/// Кадр 40×40 BGRA из четырёх четвертей: яркое белое, оранжевая лампа, тёмное
/// дерево стола и тёмно-серая стена. Отбор обязан взять первую четверть в
/// `cool`, вторую — в `warm`, а две последние — никуда.
RawLampFrame _mixedFrame() {
  const int size = 40;
  final Uint8List pixels = Uint8List(size * size * 4);
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      final int index = (y * size + x) * 4;
      final List<int> rgb =
          y < 20
          ? (x < 20
                ? <int>[255, 255, 255] // белая лампа: ярко и без оттенка
                : <int>[255, 150, 60]) // красная лампа: оттенок 18°, насыщенно
          : (x < 20
                ? <int>[90, 60, 30] // дерево стола: тот же оттенок, но темно
                : <int>[100, 100, 100]); // тёмная стена: оттенка нет, яркости нет
      pixels[index] = rgb[2]; // B
      pixels[index + 1] = rgb[1]; // G
      pixels[index + 2] = rgb[0]; // R
      pixels[index + 3] = 255; // A
    }
  }
  return RawLampFrame(
    receivedAt: DateTime.fromMillisecondsSinceEpoch(0),
    width: size,
    height: size,
    format: PixelFormatKind.bgra8888,
    pixels: pixels,
  );
}

const LampRoi _quarterLeftTop = LampRoi(
  left: 0,
  top: 0,
  width: 0.5,
  height: 0.5,
);

void main() {
  group('HSV-отбор пикселя', () {
    test('белое/оранжевое/дерево/стена раскладываются по признакам', () {
      // Отбор включается только в режиме HSV: в двух прежних эти доли не читаются,
      // и платить за них hot-циклом нельзя.
      final LampConfig config = const LampConfig(
        hsvReference: true,
        liveReference: false,
      );
      final FeatureExtractor extractor = FeatureExtractor(config);

      final FrameFeatures cool = extractor.extractRoi(
        _mixedFrame(),
        _quarterLeftTop,
      );
      expect(cool.coolFrac, 1, reason: 'вся четверть — добела залитый колпак');
      expect(cool.warmFrac, 0);

      final FrameFeatures warm = extractor.extractRoi(
        _mixedFrame(),
        const LampRoi(left: 0.5, top: 0, width: 0.5, height: 0.5),
      );
      expect(warm.warmFrac, 1, reason: 'оранжевая лампа попадает в окно ±45°');
      expect(warm.coolFrac, 0);

      final FrameFeatures wood = extractor.extractRoi(
        _mixedFrame(),
        const LampRoi(left: 0, top: 0.5, width: 0.5, height: 0.5),
      );
      expect(wood.warmFrac, 0, reason: 'дерево стола по оттенку совпадает, но тёмное');
      expect(wood.coolFrac, 0);

      final FrameFeatures wall = extractor.extractRoi(
        _mixedFrame(),
        const LampRoi(left: 0.5, top: 0.5, width: 0.5, height: 0.5),
      );
      expect(wall.coolFrac, 0, reason: 'тёмная стена не «белый свет»');
      expect(wall.warmFrac, 0);
    });

    test('в прежних режимах доли не считаются', () {
      // Оба прежних режима названы прямо: рабочий способ по умолчанию теперь
      // HSV (журнал 46), и без этого контроль проверял бы сам рабочий способ,
      // а не то, что он ничего не ломает в прежних.
      for (final LampConfig config in <LampConfig>[
        const LampConfig(liveReference: false, hsvReference: false),
        const LampConfig(liveReference: true, hsvReference: false),
      ]) {
        final FrameFeatures f = FeatureExtractor(
          config,
        ).extractRoi(_mixedFrame(), _quarterLeftTop);
        expect(f.coolFrac, 0, reason: 'доли не должны считаться в ${config.countMode}');
        expect(f.warmFrac, 0);
        expect(f.whiteFrac, 1, reason: 'обычный белый признак остался');
      }
    });
  });

  group('HSV-отсчёт', () {
    test('без трёх состояний счёт не запускается, и это сказано словами', () {
      // С 25.11.2026 цветовой счёт работает только с калибровкой (журнал 46), и
      // опирается сессия ровно на эти два числа: [LampDetector.canEvaluate] без
      // трёх состояний ложен, а [LampDetector.hsvNaming] обязана объяснить
      // оператору, чего не хватает, вместо молчаливого нуля событий.
      final LampDetector d = LampDetector(
        const LampConfig(hsvReference: true, liveReference: false),
      );
      expect(d.isCalibrated, isFalse);
      expect(d.canEvaluate, isFalse);
      expect(d.hsvNaming, contains('калибровки нет'));

      // Один снятый шаг — ещё не калибровка: решать по фону нечем.
      final LampFrame dark = LampFrame(
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
        white: _zone(),
        red: _zone(),
      );
      for (int i = 0; i < d.config.calibrationFrames; i++) {
        d.addCalibrationFrame(dark);
      }
      expect(d.canEvaluate, isFalse, reason: 'одного «фона» не хватает');
    });

    test('до warmup решения нет', () {
      final _HsvBench bench = _HsvBench();
      bench.feed(whiteCool: 0.9);
      expect(bench.detector.liveWarmupLeft, greaterThan(0));
      expect(bench.events, isEmpty);
    });

    test('вспышка белой лампы — одно белое событие, красных ноль', () {
      final _HsvBench bench = _HsvBench();
      bench.warmup();
      for (int i = 0; i < 5; i++) {
        bench.feed(whiteCool: 0.9);
      }
      expect(bench.whiteHits, 1);
      expect(bench.redHits, 0);
      expect(bench.last!.whiteLit, isTrue, reason: 'горение ещё не закрыто');
      // Событие открывается на втором подтверждённом кадре и остаётся открытым,
      // пока лампа горит: гаснет она отдельным подтверждением.
      for (int i = 0; i < 8; i++) {
        bench.feed(whiteCool: 0.9);
      }
      expect(bench.whiteHits, 1, reason: 'горение не дробится на события');
      for (int i = 0; i < 6; i++) {
        bench.feed();
      }
      expect(bench.whiteHits, 1);
      expect(bench.last!.whiteLit, isFalse);
    });

    test('вспышка красной лампы — одно красное событие', () {
      final _HsvBench bench = _HsvBench();
      bench.warmup();
      for (int i = 0; i < 5; i++) {
        bench.feed(redWarm: 0.8);
      }
      expect(bench.redHits, 1);
      expect(bench.whiteHits, 0);
    });

    test('вето: белая лампа, выбелившая красную зону, не даёт красной вспышки', () {
      // Правило снято с 11 видео стенда: без вето модель считает 64 белых и 46
      // красных события (`tools/hsv_decide.py sweep`). Перетекание здесь то же:
      // выбеливая красную зону, белая лампа поднимает там `cool` сильнее, чем
      // красная лампа поднимает собственный `warm`. Подъёмы взяты в отношении
      // 3.4 — больше `hsvGate` (3.0), который выбран по человеческой разметке
      // 23.11.2026: по ней 17 ошибок вместо 23 при 1.5 (`hsv_decide.py cmp`).
      final _HsvBench bench = _HsvBench();
      bench.warmup();
      for (int i = 0; i < 5; i++) {
        bench.feed(
          whiteCool: 0.95,
          redWarm: 0.28,
          redCool: 0.95,
        );
      }
      expect(bench.whiteHits, 1);
      expect(bench.redHits, 0, reason: 'чужой подъём в красной зоне больше своего');
    });

    test('пересвет без доказательства цвета не меняет состояние', () {
      final _HsvBench bench = _HsvBench();
      bench.warmup();
      // Белая вспышка уже открыла событие…
      for (int i = 0; i < 4; i++) {
        bench.feed(whiteCool: 0.9);
      }
      expect(bench.whiteHits, 1);
      // …а теперь зона упёрлась в потолок сенсора, и оба цвета заметны: цвет не
      // доказать, канал обязан залежать, а не погаснуть и не зажечься заново.
      for (int i = 0; i < 10; i++) {
        bench.feed(whiteCool: 0.98, whiteWarm: 0.5, whiteV: 1.0);
      }
      expect(bench.whiteHits, 1, reason: 'не переоткрылось');
      expect(bench.redHits, 0);
      expect(bench.detector.liveReading.whiteAboveOn, isFalse);
      expect(bench.detector.liveReading.whiteBelowOff, isFalse);
    });

    test('шум фона в 6σ не рождает события', () {
      final _HsvBench bench = _HsvBench();
      // Фон гуляет на 0.02↔0.06: подъём 0.04 при minRise 0.06 и σ-пороге.
      double cool = 0.02;
      for (int i = 0; i < 60; i++) {
        cool = cool > 0.04 ? 0.02 : 0.06;
        bench.feed(whiteCool: cool, redWarm: cool / 2);
      }
      expect(bench.events, isEmpty);
    });

    test('смена способа счёта сбрасывает окна: единицы разные', () {
      final _HsvBench bench = _HsvBench();
      bench.warmup();
      expect(bench.detector.liveWarmupLeft, 0);
      bench.detector.config = const LampConfig(hsvReference: false, liveReference: true);
      expect(bench.detector.liveWarmupLeft, greaterThan(0));
      bench.detector.config = const LampConfig(hsvReference: true, liveReference: false);
      expect(bench.detector.liveWarmupLeft, greaterThan(0));
    });

    test('долгое горение с мерцанием — одно событие, «пол» не догоняет лампу', () {
      // Окно — 20 кадров, горение — 60. Без заморозки «пол» поднимался до
      // уровня лампы, подъём падал в ноль, лампа «гасла» при горящем свете, а
      // колебание 0.9↔0.98 открывало второе событие.
      final _HsvBench bench = _HsvBench();
      bench.warmup();
      for (int i = 0; i < 60; i++) {
        bench.feed(whiteCool: i.isEven ? 0.9 : 0.98);
      }
      expect(bench.whiteHits, 1, reason: 'горение не считается заново');
      expect(bench.last!.whiteLit, isTrue, reason: 'лампа ещё горит');
      for (int i = 0; i < 6; i++) {
        bench.feed();
      }
      expect(bench.last!.whiteLit, isFalse, reason: 'возврат к «полу» гасит');
      expect(bench.whiteHits, 1);
    });

    test('серия вспышек с короткими паузами считается целиком', () {
      // Лампа горит больше 80% окна: без заморозки «пол» уходит наверх, и
      // следующая вспышка не поднимается над ним.
      final _HsvBench bench = _HsvBench();
      bench.warmup();
      for (int shot = 0; shot < 6; shot++) {
        for (int i = 0; i < 14; i++) {
          bench.feed(whiteCool: 0.9);
        }
        for (int i = 0; i < 3; i++) {
          bench.feed();
        }
      }
      expect(bench.whiteHits, 6);
      expect(bench.redHits, 0);
    });

    test('красная включилась — залипшая «горящая» белая закрывается', () {
      // Лампы горят по очереди. Белая канал держится в гистерезисной зоне
      // (подъём 0.04: не выше ON, не ниже OFF) — гашение не подтверждается.
      final _HsvBench bench = _HsvBench();
      bench.warmup();
      for (int i = 0; i < 5; i++) {
        bench.feed(whiteCool: 0.9);
      }
      expect(bench.whiteHits, 1);
      for (int i = 0; i < 6; i++) {
        bench.feed(whiteCool: 0.06);
      }
      expect(bench.last!.whiteLit, isTrue, reason: 'залипла: ни ON, ни OFF');
      for (int i = 0; i < 4; i++) {
        bench.feed(whiteCool: 0.06, redWarm: 0.8);
      }
      expect(bench.redHits, 1);
      expect(bench.last!.whiteLit, isFalse, reason: 'красная закрыла белую');
      for (int i = 0; i < 6; i++) {
        bench.feed();
      }
      for (int i = 0; i < 4; i++) {
        bench.feed(whiteCool: 0.9);
      }
      expect(bench.whiteHits, 2, reason: 'следующая белая вспышка не потеряна');
    });
  });

  // Замер 25.11.2026 на офисном стенде (журнал 36–37): «у своей лампы поднят
  // свой канал» там неверно физически. Красная лампа пережигает оранжевый
  // колпак в белое пятно, и её `cool` в обеих зонах больше, чем у белой; белая
  // лампа в своей рамке почти не видна и заметна только тёплым ореолом на
  // соседнем колпаке. Ниже — ровно эта картина.
  group('именование вспышек по калибровке', () {
    test('красная остаётся красной, а белая — белой', () {
      final _HsvBench bench = _HsvBench();
      // До набора «пола»: setBaseline сбрасывает окна.
      bench.detector.setBaseline(_invertedStand());
      bench.warmup();
      // Красная: выбеливает обе зоны. Прежнее правило с вето [LampConfig.hsvGate]
      // видит в этом подъёме белую лампу.
      for (int i = 0; i < 4; i++) {
        bench.feed(
          whiteCool: 0.72,
          whiteWarm: 0.02,
          redCool: 0.60,
          redWarm: 0.25,
        );
      }
      for (int i = 0; i < 6; i++) {
        bench.feed();
      }
      // Белая: почти незаметна в своей рамке, видна тёплым ореолом чужой.
      for (int i = 0; i < 4; i++) {
        bench.feed(
          whiteCool: 0.04,
          whiteWarm: 0.02,
          redCool: 0.02,
          redWarm: 0.12,
        );
      }
      for (int i = 0; i < 6; i++) {
        bench.feed();
      }
      expect(bench.redHits, 1, reason: 'пережжённый колпак не стал белой');
      expect(bench.whiteHits, 1, reason: 'слабая белая не стала красной');
    });

    test('без выученного правила та же белая вспышка считается красной', () {
      // Контроль к предыдущему: правило было сломано не порогом, а догадкой, и
      // выключенный флаг [LampConfig.hsvSignatureNaming] возвращает именно
      // прежнее поведение.
      final _HsvBench bench = _HsvBench(
        config: const LampConfig(
          hsvReference: true,
          liveReference: false,
          hsvSignatureNaming: false,
        ),
      );
      bench.detector.setBaseline(_invertedStand());
      bench.warmup();
      for (int i = 0; i < 4; i++) {
        bench.feed(
          whiteCool: 0.04,
          whiteWarm: 0.02,
          redCool: 0.02,
          redWarm: 0.12,
        );
      }
      expect(bench.redHits, 1);
      expect(bench.whiteHits, 0);
    });

    test('калибровка без разделения ламп права называть не даёт', () {
      // Состояния «белая» и «красная» одинаковы — учиться нечему (так вышло на
      // записях iPhone: красная лампа выбита в белый). Детектор обязан остаться
      // на прежнем правиле с вето, а не называть лампы монеткой.
      final _HsvBench bench = _HsvBench();
      bench.detector.setBaseline(_blindStand());
      bench.warmup();
      for (int i = 0; i < 5; i++) {
        bench.feed(redWarm: 0.8);
      }
      expect(bench.redHits, 1);
      expect(bench.whiteHits, 0);
    });
  });
}

/// Состояние калибровки в HSV-единицах: четыре ряда и их σ внутри шага.
CalibrationState _state({
  required double wCool,
  required double wWarm,
  required double rCool,
  required double rWarm,
  double sigma = 0.005,
}) {
  FrameFeatures zone(double cool, double warm) => FrameFeatures(
    meanY: 30,
    p90Luma: 30,
    sampleCount: 400,
    coolFrac: cool,
    warmFrac: warm,
  );
  return CalibrationState(
    white: zone(wCool, wWarm),
    red: zone(rCool, rWarm),
    whiteSigma: zone(sigma, sigma),
    redSigma: zone(sigma, sigma),
    frameCount: 15,
  );
}

/// Калибровка офисного стенда: красная лампа даёт большой подъём `cool` в обеих
/// зонах, белая — только тёплый ореол в чужой рамке.
LampBaseline _invertedStand() => LampBaseline(
  background: _state(wCool: 0.02, wWarm: 0.01, rCool: 0.02, rWarm: 0.03),
  whiteOn: _state(wCool: 0.04, wWarm: 0.02, rCool: 0.02, rWarm: 0.12),
  redOn: _state(wCool: 0.72, wWarm: 0.02, rCool: 0.60, rWarm: 0.25),
  capturedAtMs: 0,
);

/// То же, но обе лампы меняют кадр одинаково: разделения нет ни по одному из
/// 16 признаков.
LampBaseline _blindStand() => LampBaseline(
  background: _state(wCool: 0.02, wWarm: 0.01, rCool: 0.02, rWarm: 0.03),
  whiteOn: _state(wCool: 0.50, wWarm: 0.10, rCool: 0.50, rWarm: 0.10),
  redOn: _state(wCool: 0.50, wWarm: 0.10, rCool: 0.50, rWarm: 0.10),
  capturedAtMs: 0,
);
