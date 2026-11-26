import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_detection/lamp_detection.dart';

import 'support/session_fakes.dart';
import 'support/synthetic_scene.dart';

/// Свет и рамки — это УСЛОВИЕ измерений, а не обстановка прогона. Здесь
/// проверяется, что ни одно решение не принимается по эталонам, снятым при
/// другом свете или в других местах кадра (инструкция, п. 5, 6, критерий 7).
void main() {
  const Scene scene = Scene();
  const int baseNs = 20000000;
  const double baseGain = 100;

  group('База измерений', () {
    test('ExposureGuard: джиттер — не смена, метка без метки — не пара', () {
      final ExposureGuard guard = ExposureGuard();
      // Меток нет — базы нет, и выдумывать её по первому кадру нельзя.
      expect(guard.checkAndAdopt(), isNull);
      expect(guard.hasBasis, isFalse);

      guard.remember(ns: baseNs, gain: baseGain);
      // Дрожание метрик сенсора в единицы процентов — то же условие, и база от
      // него не ездит: иначе уползла бы за прогон сама, незаметно.
      expect(guard.checkAndAdopt(ns: 20100000, gain: 101), isNull);
      expect(guard.basis.ns, baseNs);
      // Шаг автоэкспозиции — уже другое условие: возвращаются прежние значения.
      final ({int? ns, double? gain})? lost = guard.checkAndAdopt(
        ns: 40000000,
        gain: baseGain,
      );
      expect(lost?.ns, baseNs);
      // Тот же скачок вторым кадром не повторяется: база уже новая.
      expect(guard.checkAndAdopt(ns: 40000000, gain: baseGain), isNull);
    });

    test('шаги калибровки при разном свете не складываются в один эталон', () {
      // Режим эталонов назван прямо: по умолчанию способ теперь HSV (журнал 46),
      // а здесь проверяется яркостной вектор без цветовых рядов.
      final LampDetector detector = LampDetector(
        const LampConfig(liveReference: false, hsvReference: false),
      );
      int index = 0;
      for (int k = 0; k < 30; k++, index++) {
        detector.addCalibrationFrame(
          lit(scene.off(index: index), exposureNs: baseNs, gain: baseGain),
        );
      }
      // Фон снят при одной выдержке, «белая горит» — при другой: разность
      // состояний была бы разностью настроек сенсора, а не откликом лампы.
      expect(
        () {
          for (int k = 0; k < 30; k++, index++) {
            detector.addCalibrationFrame(
              lit(
                scene.both(white: scene.whiteOn, index: index),
                exposureNs: 40000000,
                gain: baseGain,
              ),
            );
          }
        },
        throwsA(isA<CalibrationException>()),
      );
    });

    test('смена экспозиции в прогоне: кадр не решает, калибровка сброшена', () async {
      final rig = await TestRig.withCalibration(calibratedBaseline());
      expect(rig.session.isCalibrated, isTrue);
      for (int i = 0; i < 3; i++) {
        rig.source.emit(
          sensorFrame(index: i, luma: 40, exposureNs: baseNs, gain: baseGain),
        );
      }
      final DateTime evaluated = rig.session.lastFeatures!.timestamp;

      // Кадр вспыхивает яркостью И меняет выдержку: автоэкспозиция даёт ровно
      // такой же скачок, как включённая лампа, поэтому он обязан быть пропущен.
      rig.source.emit(
        sensorFrame(index: 3, luma: 220, exposureNs: 40000000, gain: baseGain),
      );

      expect(
        rig.session.lastFeatures!.timestamp,
        evaluated,
        reason: 'кадр со сменой света не должен попадать в оценку',
      );
      expect(rig.session.isCalibrated, isFalse);
      expect(rig.session.whiteHits + rig.session.redHits, 0);
      expect(rig.storage.saved, isEmpty);
      expect(rig.session.lastErrors.first, contains('Экспозиция сменилась'));
      await rig.session.dispose();
    });

    test('тот же свет: такой же кадр оценивается — сброс не из-за сломанного конвейера', () async {
      final rig = await TestRig.withCalibration(calibratedBaseline());
      for (int i = 0; i < 3; i++) {
        rig.source.emit(
          sensorFrame(index: i, luma: 40, exposureNs: baseNs, gain: baseGain),
        );
      }
      rig.source.emit(
        sensorFrame(index: 3, luma: 220, exposureNs: baseNs, gain: baseGain),
      );

      expect(
        rig.session.lastFeatures!.timestamp,
        DateTime.fromMillisecondsSinceEpoch(3 * 33),
      );
      expect(rig.session.isCalibrated, isTrue);
      await rig.session.dispose();
    });

    test('источник без меток экспозиции калибровку не сбрасывает', () async {
      // Симулятор и файл меток не отдают: сравнивать не с чем, а выдумывать
      // условие нельзя — иначе каждый прогон без них терял бы калибровку.
      final rig = await TestRig.withCalibration(calibratedBaseline());
      for (int i = 0; i < 4; i++) {
        rig.source.emit(sensorFrame(index: i, luma: 40 + i * 30));
      }

      expect(rig.session.isCalibrated, isTrue);
      expect(rig.session.whiteHits + rig.session.redHits, 0);
      await rig.session.dispose();
    });

    test('сдвинулись рамки — прежняя калибровка не используется', () async {
      final rig = await TestRig.withCalibration(calibratedBaseline());
      expect(rig.session.isCalibrated, isTrue);

      rig.session.updateRoi(
        // Одно перетаскивание одной рамки: измерения считались бы по другим
        // пикселям, поэтому и весь эталон теряет силу.
        const RoiLayout(
          white: LampRoi(left: 0.30, top: 0.16, width: 0.34, height: 0.26),
          red: LampRoi(left: 0.10, top: 0.56, width: 0.34, height: 0.26),
        ),
      );

      // Эталон считался по другим пикселям — значит, решения по нему нет.
      expect(rig.session.baseline, isNull);
      expect(rig.session.isCalibrated, isFalse);
      expect(rig.session.lastErrors.first, contains('Рамки сдвинулись'));
      await rig.session.dispose();
    });
  });
}
