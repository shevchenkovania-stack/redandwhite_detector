import 'package:flutter/foundation.dart' show debugPrint;
import 'package:lamp_detection/lamp_detection.dart';

import 'opencv_features.dart';

/// Второй режим: кадр меряет ТОЛЬКО OpenCV.
///
/// Ни одного числа из штатного Dart-экстрактора здесь нет. Если OpenCV не смог
/// измерить кадр, кадр становится пустым (нули), и в лог один раз пишется
/// причина. Так видно, что режим не справился, а не то, что его молча спасли
/// прежним способом.
class OpenCvSensorExtractor extends FeatureExtractor {
  OpenCvSensorExtractor({required LampConfig config})
    : _cv = OpenCvFeatureExtractor(config: config),
      super(config);

  final OpenCvFeatureExtractor _cv;

  bool _warned = false;

  @override
  set config(LampConfig value) {
    super.config = value;
    _cv.config = value;
  }

  @override
  LampFrame extract(RawLampFrame frame, RoiLayout roi, FrameMapping mapping) {
    OpenCvFrameMeasure? measured;
    try {
      measured = _cv.measure(frame, roi, mapping: mapping);
    } on Object catch (e) {
      measured = null;
      _warn('сбой OpenCV: $e');
    }
    if (measured == null) {
      _warn(
        'кадр не измерен (${frame.format.name}): '
        '${_cv.lastFailure ?? 'причина не указана'}',
      );
      return _empty(frame);
    }
    return _frame(measured, frame);
  }

  /// Ничего не измерено: ноль вместо чисел, без вызова Dart-экстрактора.
  LampFrame _empty(RawLampFrame frame) => LampFrame(
    timestamp: frame.receivedAt,
    white: FrameFeatures.zero,
    red: FrameFeatures.zero,
    exposureTimeNs: frame.exposureTimeNs,
    sensorSensitivity: frame.sensorSensitivity,
  );

  LampFrame _frame(OpenCvFrameMeasure m, RawLampFrame frame) => LampFrame(
    timestamp: frame.receivedAt,
    white: _features(m.whiteCore),
    red: _features(m.redCore),
    whiteRing: m.whiteRing == null ? null : _features(m.whiteRing!),
    redRing: m.redRing == null ? null : _features(m.redRing!),
    exposureTimeNs: frame.exposureTimeNs,
    sensorSensitivity: frame.sensorSensitivity,
  );

  FrameFeatures _features(OpenCvFeatureMeasure m) => FrameFeatures(
    meanY: m.meanY,
    sampleCount: m.pixelCount,
    whiteFrac: m.whiteFrac ?? 0,
    redFrac: m.redFrac ?? 0,
    p90Luma: m.p90Luma,
    lumaStdDev: m.lumaStdDev,
    clippedRatio: m.clippedRatio,
  );

  void _warn(String message) {
    if (_warned) {
      return;
    }
    _warned = true;
    debugPrint('OPENCVSENSOR $message');
  }

  void dispose() => _cv.dispose();
}
