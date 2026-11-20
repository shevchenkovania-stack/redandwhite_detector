import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_detection/lamp_detection.dart';

import 'support/synthetic_scene.dart';

void main() {
  const Scene scene = Scene();

  group('События по синтетическим последовательностям', () {
    test('1. Белая включилась один раз = 1 событие', () {
      final Harness h = Harness();
      final List<HitEvent> events = h.whitePulse();

      expect(events, hasLength(1));
      expect(events.single.color, HitColor.white);
      expect(events.single.lampId, 'white');
      expect(events.single.sequenceNumber, 1);
      // detectedAt = время кадра, где лампа впервые стала кандидатом ON,
      // а не время подтверждения (подтверждение = onConfirmFrames кадров).
      expect(events.single.detectedAt, scene.off(index: 90).timestamp);
    });

    test('2. Красная один раз = 1 событие', () {
      final Harness h = Harness();
      final List<HitEvent> events = h.redPulse();

      expect(events, hasLength(1));
      expect(events.single.color, HitColor.red);
      expect(events.single.lampId, 'red');
    });

    test('3. Белая 5 раз подряд с паузами = 5 событий', () {
      final Harness h = Harness();
      int index = 90;
      final List<HitEvent> events = <HitEvent>[];
      for (int n = 0; n < 5; n++) {
        events.addAll(h.whitePulse(startIndex: index));
        index += 8;
      }

      expect(events, hasLength(5));
      expect(events.map((HitEvent e) => e.sequenceNumber), <int>[1, 2, 3, 4, 5]);
      expect(events.every((HitEvent e) => e.color == HitColor.white), isTrue);
    });

    test('4. Красная 5 раз = 5 событий', () {
      final Harness h = Harness();
      int index = 90;
      final List<HitEvent> events = <HitEvent>[];
      for (int n = 0; n < 5; n++) {
        events.addAll(h.redPulse(startIndex: index));
        index += 8;
      }

      expect(events, hasLength(5));
      expect(events.every((HitEvent e) => e.color == HitColor.red), isTrue);
    });

    test('5. Белая, затем красная через короткую паузу = 2 события по порядку', () {
      final Harness h = Harness();
      final List<HitEvent> events = <HitEvent>[
        ...h.feedAll(h.scene.sequence(3, white: scene.whiteOn, startIndex: 90)),
        ...h.feedAll(h.scene.sequence(2, startIndex: 93)),
        ...h.feedAll(h.scene.sequence(3, red: scene.redOn, startIndex: 95)),
        ...h.feedAll(h.scene.sequence(5, startIndex: 98)),
      ];

      expect(events, hasLength(2));
      expect(events[0].color, HitColor.white);
      expect(events[1].color, HitColor.red);
      expect(events[0].sequenceNumber, 1);
      expect(events[1].sequenceNumber, 2);
      expect(events[1].detectedAt.isAfter(events[0].detectedAt), isTrue);
    });

    test('6. Красная, затем белая без паузы = 2 события', () {
      final Harness h = Harness();
      final List<HitEvent> events = <HitEvent>[
        ...h.feedAll(h.scene.sequence(3, red: scene.redOn, startIndex: 90)),
        // Смена без паузы: в том же кадре красная гаснет, белая загорается.
        ...h.feedAll(h.scene.sequence(3, white: scene.whiteOn, red: scene.redOff, startIndex: 93)),
      ];

      expect(events, hasLength(2));
      expect(events[0].color, HitColor.red);
      expect(events[1].color, HitColor.white);
      expect(events[0].sequenceNumber, 1);
      expect(events[1].sequenceNumber, 2);
      expect(h.machine.state, LampSessionState.whiteOn);

      // Дальше обе погасли — новых событий нет, состояние возвращается в idle.
      expect(h.feedAll(h.scene.sequence(5, startIndex: 96)), isEmpty);
      expect(h.machine.state, LampSessionState.idle);
    });

    test('7. Лампа горит 3 секунды = 1 событие', () {
      final Harness h = Harness();
      // 30 fps * 3 с = 90 кадров подряд.
      final List<HitEvent> events = h.feedAll(h.scene.sequence(90, white: scene.whiteOn, startIndex: 90));

      expect(events, hasLength(1));
      expect(h.machine.state, LampSessionState.whiteOn);
    });

    test('8. Шум фона (доли пикселей ±0.01, яркость ±6) = 0 событий', () {
      final Harness h = Harness();
      final List<HitEvent> events = <HitEvent>[];
      for (int i = 90; i < 390; i++) {
        events.addAll(h.feed(scene.noisy(index: i, jitterY: 6)));
      }

      expect(events, isEmpty);
    });

    test('9. Рука в ROI (скачок короче подтверждения) = 0 событий', () {
      final Harness h = Harness();
      final List<HitEvent> events = <HitEvent>[
        // Один кадр яркого пятна (палец закрыл лампу/блик) — меньше onConfirmFrames.
        ...h.feedAll(h.scene.sequence(1, white: scene.whiteOn, startIndex: 90)),
        ...h.feedAll(h.scene.sequence(4, startIndex: 91)),
        ...h.feedAll(h.scene.sequence(1, red: scene.redOn, startIndex: 95)),
        ...h.feedAll(h.scene.sequence(4, startIndex: 96)),
      ];

      expect(events, isEmpty);
      expect(h.machine.state, LampSessionState.idle);
    });

    test('10. Чужая засветка белой ROI не даёт события белой', () {
      // Красная лампа подсветила и белую рамку. Физически её собственный колпак
      // при этом ярче, иначе свет в белой рамке и был бы белой лампой. Поэтому
      // кадр строится из одного и того же поднятия: своя рамка — целиком,
      // чужая — на четверть своего отклика.
      final Harness h = Harness();
      final List<HitEvent> events = h.feedAll(
        h.scene.sequence(
          6,
          white: _blend(scene.whiteOff, scene.whiteOn, 0.25),
          red: scene.redOn,
          startIndex: 90,
        ),
      );

      expect(events.where((HitEvent e) => e.color == HitColor.white), isEmpty);
      expect(events, hasLength(1));
      expect(events.single.color, HitColor.red);
    });

    test('10b. Прежний способ: яркие, но НЕ белые пиксели белой не считаются', () {
      // Кадр физически противоречивый: чужая рамка поднялась ЯРЧЕ своей, так
      // что яркостью источник не назвать. Он проверяет именно цветовое
      // решение (spatialVectors = false), где «белый» пиксель — это min(R,G,B)
      // над порогом, а не просто светло.
      final Harness h = Harness(
        config: const LampConfig(liveReference: false, spatialVectors: false),
      );
      final List<HitEvent> events = h.feedAll(
        h.scene.sequence(6, white: scene.whiteTintedByRed, red: scene.redOn, startIndex: 90),
      );

      expect(events.where((HitEvent e) => e.color == HitColor.white), isEmpty);
      expect(events, hasLength(1));
      expect(events.single.color, HitColor.red);
    });

    test('11. Обе лампы горят одновременно: ДВА независимых события', () {
      final Harness h = Harness();
      final List<HitEvent> events = h.feedAll(
        h.scene.sequence(5, white: scene.whiteOn, red: scene.redOn, startIndex: 90),
      );

      // Белая и красная — независимые лампы: одновременная вспышка это две
      // вспышки, а не одна «неоднозначная».
      expect(events, hasLength(2));
      expect(events.map((HitEvent e) => e.color).toSet(), <HitColor>{
        HitColor.white,
        HitColor.red,
      });
      // Флаг неоднозначности остался только как диагностика.
      expect(h.ambiguousFrames, 5);
    });

    test('11b. Обе одновременно погасли — новых событий нет', () {
      final Harness h = Harness();
      h.feedAll(h.scene.sequence(5, white: scene.whiteOn, red: scene.redOn, startIndex: 90));
      final List<HitEvent> after = h.feedAll(h.scene.sequence(5, startIndex: 95));

      expect(after, isEmpty);
      expect(h.machine.state, LampSessionState.idle);
    });

    // Одно физическое горение — волна: амплитуда проседает внутри вспышки.
    // Просадка не должна закрывать событие, а падение к «полу» — обязана.
    // Различает их глубина (инструкция, п. 7): выключенную лампу не видно
    // совсем, волна лампу не гасит.
    test('12. Вспышка с двумя волнами внутри = 1 событие', () {
      final Harness h = Harness();
      final FrameFeatures dip = _blend(scene.whiteOff, scene.whiteOn, 0.2);
      final List<HitEvent> events = <HitEvent>[
        ...h.feedAll(h.scene.sequence(3, white: scene.whiteOn, startIndex: 90)),
        ...h.feedAll(h.scene.sequence(3, white: dip, startIndex: 93)),
        ...h.feedAll(h.scene.sequence(3, white: scene.whiteOn, startIndex: 96)),
        ...h.feedAll(h.scene.sequence(3, white: dip, startIndex: 99)),
        ...h.feedAll(h.scene.sequence(3, white: scene.whiteOn, startIndex: 102)),
      ];

      expect(events, hasLength(1));
      expect(h.machine.state, LampSessionState.whiteOn);
    });

    test('13. Тот же провал: к полу — второе событие, к середине — нет', () {
      final Harness h = Harness();
      final List<HitEvent> deep = <HitEvent>[
        ...h.feedAll(h.scene.sequence(3, white: scene.whiteOn, startIndex: 90)),
        // Лампу выключили: амплитуда ушла к нулю — гашение подтверждено.
        ...h.feedAll(h.scene.sequence(3, startIndex: 93)),
        ...h.feedAll(h.scene.sequence(3, white: scene.whiteOn, startIndex: 96)),
      ];
      expect(deep, hasLength(2));

      // Те же три кадра, но не до гашения, а до просадки — второй вспышки нет.
      final Harness shallow = Harness();
      shallow.feedAll(shallow.scene.sequence(3, white: scene.whiteOn, startIndex: 90));
      final List<HitEvent> after = shallow.feedAll(
        shallow.scene.sequence(
          3,
          white: _blend(shallow.scene.whiteOff, shallow.scene.whiteOn, 0.2),
          startIndex: 93,
        ),
      );
      expect(after, isEmpty);
      expect(shallow.machine.state, LampSessionState.whiteOn);
    });
  });

  group('LampDetector: эталоны и измеренный уровень срабатывания', () {
    // Формул whiteScore/redScore больше нет: кадр раскладывается на два
    // эталона, набранные на калибровке, поэтому и проверки — про эталоны,
    // замороженный фон и уровень, а не про «долю пикселей над порогом».
    test('baseline заморожен: кадры ярче фона его не сдвигают', () {
      final Harness h = Harness();
      final CalibrationState before = h.detector.baseline!.background;

      h.feedAll(h.scene.sequence(20, startIndex: 90));
      h.feedAll(h.scene.sequence(20, white: scene.whiteOn, startIndex: 110));

      expect(h.detector.baseline!.background.white.meanY, before.white.meanY);
      expect(h.detector.baseline!.background.white.whiteFrac, before.white.whiteFrac);
      expect(h.detector.baseline!.background.red.redFrac, before.red.redFrac);
    });

    test('уровень срабатывания измеряется на калибровке и не зависит от кадров', () {
      final Harness h = Harness();
      final double whiteOn = h.detector.whiteOnLevel!;

      // Постоянно горящая белая 120 кадров: фон не меняется, значит и уровень
      // стоит на месте — прежний скользящий средний сдвигал его за 10 секунд.
      h.feedAll(h.scene.sequence(120, white: scene.whiteOn, startIndex: 90));

      expect(h.detector.whiteOnLevel, whiteOn);
      expect(whiteOn, greaterThanOrEqualTo(h.config.hitFraction));
      expect(h.detector.redOnLevel, greaterThanOrEqualTo(h.config.hitFraction));
    });

    test('между OFF и ON ничего не подтверждается, ниже OFF — гаснет', () {
      final Harness h = Harness();
      // Ровно половина измеренного отклика белой: 0.5 > OFF (0.6·0.6 = 0.36),
      // но < ON (0.6) — гистерезисная зона.
      final List<HitEvent> on = h.feedAll(
        h.scene.sequence(6, white: scene.whiteOn, startIndex: 90),
      );
      expect(on, hasLength(1));
      final List<HitEvent> zone = h.feedAll(
        h.scene.sequence(
          6,
          white: _blend(scene.whiteOff, scene.whiteOn, 0.5),
          startIndex: 96,
        ),
      );
      expect(zone, isEmpty);
      expect(h.machine.state, LampSessionState.whiteOn);
      final List<HitEvent> off = h.feedAll(h.scene.sequence(6, startIndex: 102));
      expect(off, isEmpty);
      expect(h.machine.state, LampSessionState.idle);
    });

    test('новый фон даёт новый baseline только через калибровку', () {
      final Harness h = Harness(scene: _BrightScene());

      expect(h.detector.baseline!.background.white.whiteFrac, closeTo(0.40, 1e-12));
      expect(h.detector.baseline!.whiteOn.white.whiteFrac, closeTo(0.70, 1e-12));
    });

    test('калибровка отвергает шаг, на котором лампа ничего не изменила', () {
      // Фон = 0.40 белых пикселей, и «белая горит» даёт ровно те же признаки:
      // эталон нулевой. Молча принять такое состояние — значит получить немой
      // канал, поэтому шаг 2 бросается прямо здесь.
      const Scene flat = Scene(
        whiteOff: FrameFeatures(
          meanY: 200,
          p90Luma: 235,
          sampleCount: 400,
          whiteFrac: 0.40,
          redFrac: 0.01,
        ),
      );
      expect(
        () => Harness(scene: flat),
        throwsA(isA<CalibrationException>()),
      );
    });

    test('без калибровки в три состояния evaluate бросает StateError', () {
      // Режим эталонов: решать нечем, пока не набраны три состояния. Живой
      // отсчёт калибровки не требует — это проверяет live_reference_test.
      final LampDetector detector = LampDetector(const LampConfig(liveReference: false));
      // Одно состояние (так было раньше) эталонов не даёт — решать нечем.
      for (int i = 0; i < 30; i++) {
        detector.addCalibrationFrame(scene.off(index: i));
      }
      expect(() => detector.evaluate(scene.off(index: 30)), throwsStateError);
    });
  });
}

/// Кадр между двумя состояниями одной рамки: `t = 0` — фон, `1` — лампа горит.
/// Перемешиваются ОБА способа измерения: и доля «своих» пикселей, и яркость
/// (средняя и верх распределения). Иначе промежуточный кадр физически
/// несогласован: тёмный колпак с яркой верхушкой.
FrameFeatures _blend(FrameFeatures from, FrameFeatures to, double t) => FrameFeatures(
  meanY: from.meanY + (to.meanY - from.meanY) * t,
  p90Luma: from.p90Luma + (to.p90Luma - from.p90Luma) * t,
  sampleCount: from.sampleCount,
  whiteFrac: from.whiteFrac + (to.whiteFrac - from.whiteFrac) * t,
  redFrac: from.redFrac + (to.redFrac - from.redFrac) * t,
);

/// Светлая сцена: в фоне уже 40% белых пикселей, но лампа на нём видна —
/// прирост есть, и калибровка обязана пройти.
class _BrightScene extends Scene {
  _BrightScene() : super(
        whiteOff: FrameFeatures(
          meanY: 200,
          p90Luma: 225,
          sampleCount: 400,
          whiteFrac: 0.40,
          redFrac: 0.01,
        ),
      );

  @override
  FrameFeatures get whiteOn => const FrameFeatures(
    meanY: 240,
    p90Luma: 252,
    sampleCount: 400,
    whiteFrac: 0.70,
    redFrac: 0.01,
  );
}
