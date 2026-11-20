import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Size, Widget;

import '../models/roi.dart';

/// Формат пиксельных данных кадра, нейтральный к плагину `camera`.
enum PixelFormatKind { yuv420, bgra8888, unsupported }

/// Один сырой кадр с камеры.
///
/// Данные передаются как есть (плоскости YUV или упакованные BGRA) — никакой
/// конверсии в RGB здесь не делается, этим занимается FeatureExtractor.
class RawLampFrame {
  const RawLampFrame({
    required this.receivedAt,
    required this.width,
    required this.height,
    required this.format,
    this.luma,
    this.lumaStride,
    this.chromaU,
    this.chromaV,
    this.chromaStride,
    this.chromaPixelStride,
    this.pixels,
    this.pixelStride,
    this.rowStride,
    this.exposureTimeNs,
    this.sensorSensitivity,
  });

  /// Время прихода кадра в image stream. Плагин `camera` 0.12 метку кадра не
  /// отдаёт, поэтому это единственный доступный источник времени кадра.
  final DateTime receivedAt;

  final int width;
  final int height;
  final PixelFormatKind format;

  /// YUV420: плоскость яркости.
  final Uint8List? luma;
  final int? lumaStride;

  /// YUV420: плоскости цветности. На Android это отдельные U и V (или две
  /// области одного semi-planar буфера), stride'ы обязательны для учёта
  /// выравнивания строк.
  final Uint8List? chromaU;
  final Uint8List? chromaV;
  final int? chromaStride;
  final int? chromaPixelStride;

  /// BGRA8888: упакованные пиксели.
  final Uint8List? pixels;
  final int? pixelStride;
  final int? rowStride;

  /// Диагностика автоэкспозиции: если эти значения дрейфуют, baseline плывёт.
  final int? exposureTimeNs;
  final double? sensorSensitivity;
}

/// Событие статуса источника кадров (ошибки не должны ронять приложение).
class FrameSourceStatus {
  const FrameSourceStatus(this.message, {this.isError = true});

  final String message;
  final bool isError;

  @override
  String toString() => message;
}

/// Абстракция источника кадров: детектору не важно, приходит ли кадр с камеры,
/// из файла или из теста.
abstract interface class FrameSource {
  /// Поток сырых кадров. Новый кадр приходит только когда предыдущий обработан
  /// (обработчик вызывается синхронно из колбэка плагина).
  Stream<RawLampFrame> get frames;

  /// Ошибки и служебные сообщения источника.
  Stream<FrameSourceStatus> get status;

  bool get isRunning;

  /// Размер превью в логических пикселях для наложения ROI.
  Size? get previewSize;

  /// Соответствие между координатами превью и координатами пикселей кадра.
  /// Для файлов и тестов — [FrameMapping.identity].
  FrameMapping get mapping;

  /// Виджет превью камеры. Возвращается из пакета, чтобы демо-приложение
  /// не зависело от плагина `camera` напрямую.
  Widget buildPreview();

  Future<void> start();

  /// Полностью останавливает image stream. Повторный [start] обязан работать
  /// без перезапуска приложения.
  Future<void> stop();

  Future<void> dispose();
}

/// Источник, который умеет вручную менять соответствие превью <-> кадр.
/// Нужно, когда авто-расчёт по sensorOrientation не угадал на конкретном
/// устройстве: в демо это кнопка «поворот ROI».
abstract interface class FrameMappingControl {
  void setFrameMapping(int quarterTurns, {bool mirror = false});
}

/// Источник, которым можно управлять экспозицией.
///
/// Всё измерение стоит на том, что «ноль» кадра за время набора не уезжает.
/// Автоэкспозиция этого не гарантирует: она пересчитывается на каждом кадре, и
/// один её шаг по яркости детектор читает как включение или выключение лампы
/// (замер на стенде: Y фона 125.5 → 99.6 между шагами калибровки). Поэтому
/// сессия обязана иметь возможность отпустить экспозицию, дать ей сойтись и
/// снова запереть — и знать, заперлась ли она вообще.
abstract interface class ExposureControl {
  /// True, если экспозиция реально зафиксирована на текущем потоке кадров.
  bool get exposureLocked;

  /// Отпустить автоэкспозицию, дать сенсору сойтись и снова зафиксировать.
  /// Вызывается перед набором каждого шага калибровки.
  Future<void> relockExposure();

  /// Увести экспозицию на шаг вниз и зафиксировать снова — защита от пересвета:
  /// в клиппинге нет ни цвета, ни яркости, канал в такой сцене слепой.
  /// Возвращает false, если устройство управлять экспозицией не даёт.
  Future<bool> reduceExposure();
}
