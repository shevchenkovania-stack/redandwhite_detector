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
      expect(events.single.detectedAt, scene.off(index: 30).timestamp);
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
      int index = 30;
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
      int index = 30;
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
        ...h.feedAll(h.scene.sequence(3, white: scene.whiteOn, startIndex: 30)),
        ...h.feedAll(h.scene.sequence(2, startIndex: 33)),
        ...h.feedAll(h.scene.sequence(3, red: scene.redOn, startIndex: 35)),
        ...h.feedAll(h.scene.sequence(5, startIndex: 38)),
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
        ...h.feedAll(h.scene.sequence(3, red: scene.redOn, startIndex: 30)),
        // Смена без паузы: в том же кадре красная гаснет, белая загорается.
        ...h.feedAll(h.scene.sequence(3, white: scene.whiteOn, red: scene.redOff, startIndex: 33)),
      ];

      expect(events, hasLength(2));
      expect(events[0].color, HitColor.red);
      expect(events[1].color, HitColor.white);
      expect(events[0].sequenceNumber, 1);
      expect(events[1].sequenceNumber, 2);
      expect(h.machine.state, LampSessionState.whiteOn);

      // Дальше обе погасли — новых событий нет, состояние возвращается в idle.
      expect(h.feedAll(h.scene.sequence(5, startIndex: 36)), isEmpty);
      expect(h.machine.state, LampSessionState.idle);
    });

    test('7. Лампа горит 3 секунды = 1 событие', () {
      final Harness h = Harness();
      // 30 fps * 3 с = 90 кадров подряд.
      final List<HitEvent> events = h.feedAll(h.scene.sequence(90, white: scene.whiteOn, startIndex: 30));

      expect(events, hasLength(1));
      expect(h.machine.state, LampSessionState.whiteOn);
    });

    test('8. Шум яркости вокруг baseline = 0 событий', () {
      final Harness h = Harness();
      final List<HitEvent> events = <HitEvent>[];
      for (int i = 30; i < 330; i++) {
        events.addAll(h.feed(scene.noisy(index: i, jitterY: 6, jitterBright: 0.02)));
      }

      expect(events, isEmpty);
    });

    test('9. Рука в ROI (скачок короче подтверждения) = 0 событий', () {
      final Harness h = Harness();
      final List<HitEvent> events = <HitEvent>[
        // Один кадр яркого пятна (палец закрыл лампу/блик) — меньше onConfirmFrames.
        ...h.feedAll(h.scene.sequence(1, white: scene.whiteOn, startIndex: 30)),
        ...h.feedAll(h.scene.sequence(4, startIndex: 31)),
        ...h.feedAll(h.scene.sequence(1, red: scene.redOn, startIndex: 35)),
        ...h.feedAll(h.scene.sequence(4, startIndex: 36)),
      ];

      expect(events, isEmpty);
      expect(h.machine.state, LampSessionState.idle);
    });

    test('10. Красная подсветка белой ROI (высокая sat) не даёт события белой', () {
      final Harness h = Harness();
      final List<HitEvent> events = h.feedAll(
        h.scene.sequence(6, white: scene.whiteTintedByRed, red: scene.redOn, startIndex: 30),
      );

      expect(events.where((HitEvent e) => e.color == HitColor.white), isEmpty);
      expect(events, hasLength(1));
      expect(events.single.color, HitColor.red);
    });

    test('11. Обе лампы выше ON-порога в одном кадре: максимум одно событие + счётчик', () {
      final Harness h = Harness();
      final List<HitEvent> events = h.feedAll(
        h.scene.sequence(5, white: scene.whiteOn, red: scene.redOn, startIndex: 30),
      );

      // white ratio = 0.35/0.15 > red ratio = 1.83/1.0 -> побеждает белая.
      expect(events.length, lessThanOrEqualTo(1));
      expect(events, hasLength(1));
      expect(events.single.color, HitColor.white);
      expect(h.ambiguousFrames, 5);
    });

    test('11b. Неоднозначный кадр не подтверждает проигравшую лампу', () {
      final Harness h = Harness();
      h.feedAll(h.scene.sequence(5, white: scene.whiteOn, red: scene.redOn, startIndex: 30));
      // Красная «горела» всё это время, но проиграла — события красной нет.
      final List<HitEvent> after = h.feedAll(h.scene.sequence(5, startIndex: 35));

      expect(after, isEmpty);
      expect(h.machine.state, LampSessionState.idle);
    });
  });

  group('LampDetector: формулы и baseline', () {
    test('whiteScore = 0 при насыщенности выше порога', () {
      const LampConfig config = LampConfig();
      final LampDetector detector = LampDetector(config);
      expect(detector.whiteScore(const FrameFeatures(meanY: 150, brightFrac: 0.3, sat: 0.55, redDom: 70, coreEdgeDiff: 20, sampleCount: 1)), 0);
      expect(detector.whiteScore(const FrameFeatures(meanY: 200, brightFrac: 0.3, sat: 0.06, redDom: 4, coreEdgeDiff: 30, sampleCount: 1)), 0.3);
    });

    test('redScore = рост яркости / 30 + 0.5 за выросшее ядро', () {
      const LampConfig config = LampConfig();
      final LampDetector detector = LampDetector(config);
      const LampBaseline baseline = LampBaseline(
        white: FrameFeatures(meanY: 60, brightFrac: 0, sat: 0, redDom: 0, coreEdgeDiff: 0, sampleCount: 1),
        red: FrameFeatures(meanY: 50, brightFrac: 0, sat: 0, redDom: 40, coreEdgeDiff: 3, sampleCount: 1),
        frameCount: 30,
      );

      // +40 яркости = 1.33, ядро выросло на 25 (>20) -> +0.5.
      expect(detector.redScore(const FrameFeatures(meanY: 90, brightFrac: 0, sat: 0, redDom: 95, coreEdgeDiff: 28, sampleCount: 1), baseline), closeTo(1.833, 0.001));
      // Ядро не выросло -> только яркость.
      expect(detector.redScore(const FrameFeatures(meanY: 90, brightFrac: 0, sat: 0, redDom: 95, coreEdgeDiff: 5, sampleCount: 1), baseline), closeTo(1.333, 0.001));
      // Нет роста яркости и нет ядра -> 0.
      expect(detector.redScore(baseline.red, baseline), 0);
    });

    test('baseline обновляется скользящим средним только когда обе лампы OFF', () {
      final Harness h = Harness();
      final LampBaseline before = h.detector.baseline!;

      // Белая горит — baseline не должен меняться.
      h.feedAll(h.scene.sequence(10, white: scene.whiteOn, startIndex: 30));
      expect(h.detector.baseline!.white.meanY, before.white.meanY);

      // Обе погасли: 10 кадров с белой ROI ярче на 20 -> baseline подтянется,
      // но не мгновенно (alpha = 0.01).
      final List<LampFrame> brighter = h.scene
          .sequence(10, startIndex: 40)
          .map(
            (LampFrame f) => LampFrame(
              timestamp: f.timestamp,
              white: FrameFeatures(
                meanY: f.white.meanY + 20,
                brightFrac: f.white.brightFrac,
                sat: f.white.sat,
                redDom: f.white.redDom,
                coreEdgeDiff: f.white.coreEdgeDiff,
                sampleCount: f.white.sampleCount,
              ),
              red: f.red,
            ),
          )
          .toList();
      h.feedAll(brighter);

      final double after = h.detector.baseline!.white.meanY;
      expect(after, greaterThan(before.white.meanY));
      expect(after, lessThan(before.white.meanY + 20));
    });

    test('OFF-порог = 60% от ON-порога', () {
      const LampConfig config = LampConfig();
      expect(config.whiteOffThreshold, config.whiteOnThreshold * 0.6);
      expect(config.redOffThreshold, config.redOnThreshold * 0.6);
    });

    test('без калибровки evaluate бросает StateError', () {
      final LampDetector detector = LampDetector(const LampConfig());
      expect(() => detector.evaluate(scene.off(index: 0)), throwsStateError);
    });
  });
}
