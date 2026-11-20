import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_detection/lamp_detection.dart';

int _ids = 0;
String _nextId() => 'live-${++_ids}';

/// Область кадра: `lit` — подъём яркости над тёмным фоном, в долях полного
/// света; `white`/`red` — доли «своих» цветных пикселей (измеряются, но не
/// решают).
///
/// Числа подобраны не случайно: `p90 / 255` равен `0.05 + lit`, поэтому подъём
/// над «полом» считается яркостью и остаётся тем же числом, что и прежняя доля
/// пикселей: одна и та же фикстура сравнивает новый способ со старыми
/// ожиданиями, а не живёт своими числами.
FrameFeatures _box({double white = 0, double red = 0, double lit = 0}) =>
    FrameFeatures(
      meanY: 13 + 242 * lit,
      p90Luma: 255 * (0.05 + lit),
      sampleCount: 400,
      whiteFrac: white,
      redFrac: red,
    );

/// Стенд как у симулятора: белая вспышка поднимает белую рамку, красная —
/// красную. Колец эти кадры не имеют (`whiteRing = null`), поэтому проверяют
/// только колпак — ровно то положение, в котором стенд и остался бы, выключи
/// он ringScale.
class _Bench {
  _Bench({LampConfig? config})
    : detector = LampDetector(config ?? const LampConfig());

  final LampDetector detector;
  final HitStateMachine machine = HitStateMachine(
    sessionId: 'live',
    idGenerator: _nextId,
  );
  final List<HitEvent> events = <HitEvent>[];
  int _frame = 0;

  List<HitEvent> feed({double white = 0.05, double red = 0.03}) {
    final int index = _frame++;
    final List<HitEvent> events = machine.onEvaluation(
      detector.evaluate(
        LampFrame(
          timestamp: DateTime.fromMillisecondsSinceEpoch(1000 + index * 100),
          white: _box(white: white, lit: white),
          red: _box(red: red, lit: red),
        ),
      ),
    );
    this.events.addAll(events);
    return events;
  }

  /// Окно отсчёта набирается из тёмных кадров: 12 кадров при окне 20.
  void warmup([int frames = 12]) {
    for (int i = 0; i < frames; i++) {
      feed();
    }
  }
}

/// Кадр 40×40 BGRA, где всё белое, кроме диска белой рамки (`0.25..0.5` по обеим
/// осям). Так видно, попадёт ли кольцо-ореол в отсчёт: колпак чёрный, ореол — 1.0.
RawLampFrame _haloFrame() {
  const int size = 40;
  final Uint8List pixels = Uint8List(size * size * 4);
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      final int index = (y * size + x) * 4;
      final bool inCore = x >= 10 && x < 20 && y >= 10 && y < 20;
      pixels[index] = inCore ? 0 : 255; // B
      pixels[index + 1] = inCore ? 0 : 255; // G
      pixels[index + 2] = inCore ? 0 : 255; // R
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

/// Кадр, у которого меняется только ореол: у живой красной лампы колпак при
/// включении бледнеет, а светит именно кольцо вокруг него.
LampFrame _haloOnly({
  required double ring,
  double core = 0.05,
  double ringRed = 0,
  int index = 0,
}) => LampFrame(
  timestamp: DateTime.fromMillisecondsSinceEpoch(1000 + index * 100),
  white: _box(white: core, lit: core),
  red: _box(red: 0.03, lit: 0.03),
  whiteRing: _box(
    white: ring,
    red: ringRed,
    lit: (ring - ringRed).clamp(0.0, 1.0),
  ),
  redRing: _box(red: 0.01, lit: 0.01),
);

/// Кадр 40×40 BGRA, где засвечено прямоугольник [left..right) × [top..bottom).
/// Нужен, чтобы проверить геометрию ореола: чужая лампа обязана вычитаться из
/// кольца вместе со своим ореолом, а не только колпаком.
RawLampFrame _spotRect(int left, int top, int right, int bottom) {
  const int size = 40;
  final Uint8List pixels = Uint8List(size * size * 4);
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      final int index = (y * size + x) * 4;
      final bool lit = x >= left && x < right && y >= top && y < bottom;
      pixels[index] = lit ? 255 : 0; // B
      pixels[index + 1] = lit ? 255 : 0; // G
      pixels[index + 2] = lit ? 255 : 0; // R
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

void main() {
  group('Зоны лампы', () {
    test('ореол меряется везде, где без него нечем решить', () {
      final RawLampFrame frame = _haloFrame();
      final RoiLayout roi = RoiLayout(
        white: const LampRoi(left: 0.25, top: 0.25, width: 0.25, height: 0.25),
        red: const LampRoi(left: 0.60, top: 0.25, width: 0.25, height: 0.25),
      );

      final LampFrame live = FeatureExtractor(
        const LampConfig(),
      ).extract(frame, roi, FrameMapping.identity);
      expect(live.white.whiteFrac, 0, reason: 'колпак чёрный');
      expect(live.whiteRing, isNotNull);
      expect(live.whiteRing!.whiteFrac, 1, reason: 'ореол залит белым');
      expect(live.redRing, isNotNull);

      // Режим эталонов обязан мерить кольца точно так же: восьмимерный вектор
      // из одних колпаков не собирается, и калибровка без ореолов отвергается.
      final LampFrame etalon = FeatureExtractor(
        const LampConfig(liveReference: false),
      ).extract(frame, roi, FrameMapping.identity);
      expect(etalon.whiteRing, isNotNull);
      expect(etalon.redRing, isNotNull);
    });

    test('кольцо лампы вычитает чужой ореол, а не только чужой колпак', () {
      // Белая рамка 0.20..0.45, красная 0.45..0.70. Засвечен ореол красной
      // лампы (её box×1.7 = 0.3625..0.7875), а её колпак тёмный. Кольцо белой
      // лампы дотягивается до 0.5375, то есть наступало бы в это пятно: если
      // вычитается только колпак, красная вспышка считается белой.
      final RoiLayout roi = RoiLayout(
        white: const LampRoi(left: 0.20, top: 0.20, width: 0.25, height: 0.25),
        red: const LampRoi(left: 0.45, top: 0.45, width: 0.25, height: 0.25),
      );
      final LampFrame live = FeatureExtractor(
        const LampConfig(),
      ).extract(_spotRect(15, 15, 32, 32), roi, FrameMapping.identity);
      expect(live.whiteRing!.whiteFrac, 0, reason: 'чужой ореол вычтен');
    });

    test('ореол сам по себе канал не решает — это чужой свет, а не лампа', () {
      final LampDetector detector = LampDetector(const LampConfig());
      final HitStateMachine machine = HitStateMachine(
        sessionId: 'halo',
        idGenerator: _nextId,
      );
      final List<HitEvent> events = <HitEvent>[];

      for (int i = 0; i < 12; i++) {
        events.addAll(
          machine.onEvaluation(
            detector.evaluate(_haloOnly(ring: 0.02, index: i)),
          ),
        );
      }
      expect(detector.whiteOnLevel, closeTo(0.03, 1e-9));

      // Колпак неподвижен, а ореол загорелся — ровно то, что делала красная
      // засветка в кольце белой лампы. События быть не должно.
      for (int i = 12; i < 17; i++) {
        events.addAll(
          machine.onEvaluation(
            detector.evaluate(_haloOnly(ring: 0.85, index: i)),
          ),
        );
      }
      expect(events, isEmpty, reason: 'Ореол без своего колпака — чужой свет');
    });

    test('ореол усиливает свою лампу: колпак сдвинулся — событие есть', () {
      final LampDetector detector = LampDetector(const LampConfig());
      final HitStateMachine machine = HitStateMachine(
        sessionId: 'halo-own',
        idGenerator: _nextId,
      );
      final List<HitEvent> events = <HitEvent>[];

      for (int i = 0; i < 12; i++) {
        events.addAll(
          machine.onEvaluation(
            detector.evaluate(_haloOnly(ring: 0.02, index: i)),
          ),
        );
      }
      // Колпак чуть шевельнулся, светит ореол — так ведёт себя живая красная
      // лампа, у которой колпак при включении ещё и бледнеет.
      for (int i = 12; i < 15; i++) {
        events.addAll(
          machine.onEvaluation(
            detector.evaluate(_haloOnly(ring: 0.85, core: 0.10, index: i)),
          ),
        );
      }
      expect(events.map((HitEvent e) => e.color), contains(HitColor.white));
    });

    test('колпак только побледнел — ореол права решать канал не получает', () {
      // У живой красной лампы колпак при включении ещё и бледнеет (замер
      // redFrac 0.727 → 0.630). Прежний цветовой способ считал движением того
      // же признака ЛЮБУЮ сторону и открывал по бледнению ореолу право решить
      // канал. Яркость так не умеет: падение яркости вспышкой быть не может по
      // определению, поэтому здесь подъём колпака — единственное, что даёт
      // ореолу голос, и этот кадр обязан остаться пустым.
      final LampDetector detector = LampDetector(const LampConfig());
      final HitStateMachine machine = HitStateMachine(
        sessionId: 'halo-pale',
        idGenerator: _nextId,
      );
      final List<HitEvent> events = <HitEvent>[];

      for (int i = 0; i < 12; i++) {
        events.addAll(
          machine.onEvaluation(
            detector.evaluate(_haloOnly(ring: 0.02, index: i)),
          ),
        );
      }
      for (int i = 12; i < 17; i++) {
        events.addAll(
          machine.onEvaluation(
            detector.evaluate(_haloOnly(ring: 0.85, core: 0.02, index: i)),
          ),
        );
      }
      expect(
        events,
        isEmpty,
        reason: 'Ореол при побледневшем колпаке — чужой свет',
      );
    });

    test(
      'чужой красный свет в кольце белой лампы не входит в её амплитуду',
      () {
        final LampDetector detector = LampDetector(const LampConfig());

        for (int i = 0; i < 12; i++) {
          detector.evaluate(_haloOnly(ring: 0.02, index: i));
        }
        // Белый признак кольца подскочил вместе с красным: сенсор перекормлен
        // красным светом. Без очистки кольцо отдало бы белой лампе свои 0.90, и
        // красная вспышка легла бы в «белую» корзину полной амплитудой.
        final LampEvaluation spill = detector.evaluate(
          _haloOnly(ring: 0.90, core: 0.10, ringRed: 0.88, index: 12),
        );
        expect(spill.whiteAmplitude, lessThan(0.2), reason: 'кольцо молчит');
        expect(spill.redAmplitude, lessThan(0.2));
      },
    );
  });

  group('Живой отсчёт: подъём над «полом» своей области', () {
    // Единицы фикстур согласованы с прежним цветовым измерением, поэтому
    // подъёмы над «полом» и пороги окна здесь — те же числа, что и в старых
    // проверках: ожидаемое поведение от смены вектора не поехало.
    LampConfig cfg() => const LampConfig();

    test('считает вспышку без калибровки, каждая — в свою корзину', () {
      final _Bench bench = _Bench(config: cfg());
      expect(bench.detector.canEvaluate, isTrue);
      expect(bench.detector.isCalibrated, isFalse);

      bench.warmup();
      expect(bench.detector.whiteOnLevel, closeTo(0.03, 1e-9));

      bench.feed(white: 0.40);
      expect(bench.events, isEmpty, reason: 'Один кадр — ещё не подтверждение');
      bench.feed(white: 0.40);
      expect(bench.events, hasLength(1));
      expect(bench.events.single.color, HitColor.white);

      for (int i = 0; i < 4; i++) {
        bench.feed();
      }
      bench.feed(red: 0.45);
      bench.feed(red: 0.45);
      expect(bench.events, hasLength(2));
      expect(bench.events.last.color, HitColor.red);
    });

    test(
      'долгое горение — одно событие, следующая вспышка снова считается',
      () {
        final _Bench bench = _Bench(config: cfg());
        bench.warmup();

        // 60 кадров подряд: лампа горит, пока её не выключат. Кадры горения в
        // окно не пишутся, поэтому «пол» не поднимается до её яркости.
        for (int i = 0; i < 60; i++) {
          bench.feed(white: 0.40);
        }
        expect(bench.events, hasLength(1));

        for (int i = 0; i < 4; i++) {
          bench.feed();
        }
        for (int i = 0; i < 3; i++) {
          bench.feed(white: 0.40);
        }
        expect(bench.events, hasLength(2));
      },
    );

    test('скачок сцены целиком — не вспышка, а новый «пол»', () {
      final _Bench bench = _Bench(config: cfg());
      bench.warmup();

      // Переключили набор картинок: поднялись ОБЕ рамки сразу. Обе лампы
      // одновременно не горят, значит это сцена, а не событие.
      for (int i = 0; i < 20; i++) {
        bench.feed(white: 0.30, red: 0.30);
      }
      expect(bench.events, isEmpty);

      for (int i = 0; i < 12; i++) {
        bench.feed(white: 0.30, red: 0.30);
      }
      expect(bench.events, isEmpty);

      // От новой сцены вспышка видна как подъём над её же уровнем.
      bench.feed(white: 0.65, red: 0.30);
      bench.feed(white: 0.65, red: 0.30);
      expect(bench.events, hasLength(1));
      expect(bench.events.single.color, HitColor.white);
    });

    test('порог берётся из шума окна, а не только из минимума', () {
      final _Bench bench = _Bench(config: cfg());
      bench.warmup();

      for (int i = 0; i < 25; i++) {
        bench.feed(white: i.isEven ? 0.06 : 0.04);
      }
      expect(bench.detector.whiteOnLevel, greaterThan(0.06));

      // +0.05 над 20-м процентилем — это ещё фон, вспышкой не считается.
      for (int i = 0; i < 3; i++) {
        bench.feed(white: 0.09);
      }
      expect(bench.events, isEmpty);

      bench.feed(white: 0.40);
      bench.feed(white: 0.40);
      expect(bench.events, hasLength(1));
    });

    test('клиппинг на старте не переоткрывает вспышку каждые 10 кадров', () {
      final _Bench bench = _Bench(config: cfg());

      // Пока нет ни одного тёмного значения, яркие кадры только ждут: пустое
      // окно не обязано превращаться в периодический ON каждые пол-окна.
      for (int i = 0; i < 40; i++) {
        bench.feed(white: 0.95);
      }
      expect(bench.events, isEmpty);
      expect(bench.detector.liveWarmupLeft, 10);

      bench.warmup();
      for (int i = 0; i < 30; i++) {
        bench.feed(white: 0.95);
      }
      expect(bench.events, hasLength(1));
      expect(bench.events.single.color, HitColor.white);
    });
  });
}
