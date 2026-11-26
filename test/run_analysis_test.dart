import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_detection/lamp_detection.dart';

import 'support/session_fakes.dart';

/// Разбор записанной серии (CSV v3) нынешним способом решения. Ценность
/// разбора в том, что он читает РОВНО ТЕ ЖЕ измеренные строки, что и живой
/// стенд: ни второго прогона, ни другой выборки. Заодно по тем же строкам
/// измеряются длительности провалов и пауз — единственные числа, которыми
/// задают `offConfirmMs` вместо догадки.
///
/// Способ счёта здесь назван прямо. Синтетические кадры ниже измеряют только
/// яркость (`whiteFrac`/`redFrac`), цветовых рядов в них нет, а рабочий способ
/// по умолчанию теперь HSV (журнал 46): без явного `mode` разбор не увидел бы
/// ни одного удара и проверял бы не то правило.
void main() {
  FrameFeatures field(
    double meanY, {
    double whiteFrac = 0.05,
    double redFrac = 0.03,
    double? p90,
    double clip = 0,
  }) => FrameFeatures(
    meanY: meanY,
    sampleCount: 400,
    whiteFrac: whiteFrac,
    redFrac: redFrac,
    p90Luma: p90 ?? meanY + 2,
    clippedRatio: clip,
  );

  /// Кадр: красная рамка показывает [red], белая — фон.
  FeatureCsvRow row(
    int index, {
    FrameFeatures? red,
    FrameFeatures? white,
    int frameMs = 33,
  }) => FeatureCsvRow(
    timestampMs: 1000 + index * frameMs,
    white: white ?? field(60),
    red: red ?? field(50),
    state: 'working',
  );

  final List<FeatureCsvRow> background = List<FeatureCsvRow>.generate(
    10,
    (int i) => row(i),
  );

  group('Разбор записи', () {
    test('пересвет красной лампы не уезжает в белую корзину', () {
      // Красная лампа на клиппинге: цветовых «красных» пикселей в ней почти не
      // осталось (пересвеченный колпак для сенсора белый). Решение берётся из
      // того, КУДА поднялась яркость, — поэтому событие красное, а не белое.
      final List<FeatureCsvRow> rows = <FeatureCsvRow>[
        ...background,
        ...List<FeatureCsvRow>.generate(
          6,
          (int i) => row(
            10 + i,
            red: field(
              250,
              whiteFrac: 0.06,
              redFrac: 0.05,
              p90: 255,
              clip: 0.6,
            ),
          ),
        ),
        ...List<FeatureCsvRow>.generate(6, (int i) => row(16 + i)),
      ];

      final RunAnalysis a = RunAnalyzer.analyze(
        FeatureCsv.encode(rows),
        mode: LampCountMode.live,
      );

      expect(a.frames, rows.length);
      expect(a.medianFrameMs, 33);
      expect(a.redEvents, 1);
      expect(a.whiteEvents, 0);
      expect(a.describe(), contains('красная'));
    });

    test('вспышка с провалом и пауза между ударами: числа измерены', () {
      final FrameFeatures flash = field(
        150,
        whiteFrac: 0.04,
        redFrac: 0.45,
        p90: 210,
      );
      // Просадка внутри горения: два кадра темноты — меньше offConfirmFrames,
      // гашение не подтверждается, горение не прервано.
      final FrameFeatures dip = field(52, whiteFrac: 0.05, redFrac: 0.03);
      final List<FeatureCsvRow> rows = <FeatureCsvRow>[
        ...background,
        ...List<FeatureCsvRow>.generate(3, (int i) => row(10 + i, red: flash)),
        ...List<FeatureCsvRow>.generate(2, (int i) => row(13 + i, red: dip)),
        ...List<FeatureCsvRow>.generate(4, (int i) => row(15 + i, red: flash)),
        // Настоящая пауза между ударами: лампа ушла к фону надолго.
        ...List<FeatureCsvRow>.generate(8, (int i) => row(19 + i)),
        ...List<FeatureCsvRow>.generate(4, (int i) => row(27 + i, red: flash)),
        ...List<FeatureCsvRow>.generate(6, (int i) => row(31 + i)),
      ];

      final RunAnalysis a = RunAnalyzer.analyze(
        FeatureCsv.encode(rows),
        mode: LampCountMode.live,
      );

      expect(a.redEvents, 2);
      expect(a.whiteEvents, 0);

      final DarkRunTiming red = a.redTiming;
      expect(red.dipsMs, isNotEmpty);
      expect(red.pausesMs, isNotEmpty);
      expect(red.separable, isTrue);
      // Правило обязано быть между ними: иначе оно режет один удар или склеивает
      // два. Проверка ровно этого, без новых чисел.
      expect(red.suggestedOffConfirmMs, greaterThan(red.maxDipMs));
      expect(red.suggestedOffConfirmMs, lessThan(red.minPauseMs));
      expect(a.describe(), contains('красная'));
    });
  });

  // Инструкция, п. 8 и критерий 8: второй способ измерения света обязан
  // сравниваться параллельно и не вмешиваться в рабочий автомат.
  group('Теневой измеритель', () {
    /// Прогон одного и того же набора кадров: без тени, с рабочей тенью и с
    /// тенью, которая бросается на каждом кадре. События во всех трёх случаях
    /// обязаны быть одинаковыми.
    Future<({int events, int frames, int rawBytes})> run({
      required Probe probe,
    }) async {
      final rig = await TestRig.withCalibration(calibratedBaseline());
      rig.session.applyConfig(const LampConfig(liveReference: false));
      int seen = 0;
      int rawBytes = 0;
      if (probe != Probe.none) {
        rig.session.shadowProbe = probe == Probe.broken
            ? (ShadowInput input) => throw StateError('тень сломалась')
            : (ShadowInput input) {
                // Тень обязана получать именно пиксели, а не только числа:
                // иначе «второй способ» меряет не кадр, а чужой отчёт.
                rawBytes = input.raw.pixels?.length ?? 0;
                seen++;
              };
      }
      for (int i = 0; i < 5; i++) {
        rig.source.emit(pixelFrame(index: i));
      }
      for (int i = 5; i < 12; i++) {
        rig.source.emit(pixelFrame(index: i, whiteOn: true));
      }
      for (int i = 12; i < 18; i++) {
        rig.source.emit(pixelFrame(index: i));
      }
      await pumpEventQueue();
      final int events = rig.session.whiteHits + rig.session.redHits;
      await rig.session.dispose();
      return (events: events, frames: seen, rawBytes: rawBytes);
    }

    test(
      'вспышка считается и без тени, и с тенью, и со сломанной тенью',
      () async {
        final ({int events, int frames, int rawBytes}) plain = await run(
          probe: Probe.none,
        );
        expect(
          plain.events,
          1,
          reason: 'вспышка белой обязана дать одно событие',
        );

        final ({int events, int frames, int rawBytes}) watched = await run(
          probe: Probe.watch,
        );
        expect(watched.events, plain.events);
        expect(
          watched.frames,
          18,
          reason: 'тень обязана видеть все обработанные кадры',
        );
        expect(
          watched.rawBytes,
          64 * 64 * 4,
          reason:
              'тени отдан тот же кадр в пикселях, что и рабочему экстрактору',
        );

        // Падение тени не имеет права ни уронить прогон, ни изменить его итог.
        final ({int events, int frames, int rawBytes}) broken = await run(
          probe: Probe.broken,
        );
        expect(broken.events, plain.events);
      },
    );
  });
}

/// Три вида прогона в тесте тени.
enum Probe { none, watch, broken }
