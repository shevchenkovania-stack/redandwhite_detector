import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../models/roi.dart';
import 'frame_source.dart';

/// Настройки захвата. [ResolutionPreset.medium] (720x480) достаточно для ROI
/// и не перегружает анализ.
class CameraSourceOptions {
  const CameraSourceOptions({
    this.resolutionPreset = ResolutionPreset.medium,
    this.lensDirection = CameraLensDirection.back,
    this.targetFps,
    this.imageFormatGroup,
    this.lockSettle = const Duration(milliseconds: 400),
  });

  final ResolutionPreset resolutionPreset;
  final CameraLensDirection lensDirection;

  /// Желаемый FPS. `null` — сколько выставит драйвер. Поддержка зависит от
  /// устройства; реально замеряется в диагностике.
  final int? targetFps;

  /// `null` = yuv420 на Android, bgra8888 на iOS.
  final ImageFormatGroup? imageFormatGroup;

  /// Пауза между запуском авто-фокуса/экспозиции и их блокировкой, чтобы
  /// сенсор успел сходиться.
  final Duration lockSettle;
}

/// Источник кадров на плагине `camera`.
class CameraFrameSource extends ChangeNotifier implements FrameSource, FrameMappingControl {
  CameraFrameSource({this.options = const CameraSourceOptions()});

  final CameraSourceOptions options;

  final StreamController<RawLampFrame> _frames = StreamController<RawLampFrame>.broadcast();
  final StreamController<FrameSourceStatus> _status = StreamController<FrameSourceStatus>.broadcast();

  CameraController? _controller;
  bool _running = false;
  bool _disposed = false;
  FrameMapping? _mappingOverride;
  FrameMapping _computed = FrameMapping.identity;
  int _unsupportedFormatWarnings = 0;

  /// Текущее соответствие превью <-> кадр.
  @override
  FrameMapping get mapping => _mappingOverride ?? _computed;

  /// Принудительная установка соответствия из UI (кнопка «поворот ROI»), когда
  /// авто-расчёт не угадал ориентацию сенсора на конкретном устройстве.
  @override
  void setFrameMapping(int quarterTurns, {bool mirror = false}) {
    _mappingOverride = FrameMapping(quarterTurns: quarterTurns % 4, mirrorHorizontal: mirror);
    notifyListeners();
  }

  @override
  Stream<RawLampFrame> get frames => _frames.stream;

  @override
  Stream<FrameSourceStatus> get status => _status.stream;

  @override
  bool get isRunning => _running;

  @override
  Size? get previewSize => _controller?.value.previewSize;

  @override
  Widget buildPreview() => LampCameraPreview(source: this);

  @override
  Future<void> start() async {
    if (_disposed || _running) {
      return;
    }
    try {
      final List<CameraDescription> cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw CameraException('noCameras', 'Камеры не найдены');
      }
      final CameraDescription description = cameras.firstWhere(
        (CameraDescription c) => c.lensDirection == options.lensDirection,
        orElse: () => cameras.first,
      );

      final CameraController controller = CameraController(
        description,
        options.resolutionPreset,
        enableAudio: false,
        fps: options.targetFps,
        imageFormatGroup: options.imageFormatGroup ?? _defaultFormatGroup(),
      );
      _controller = controller;
      await controller.initialize();
      _computed = _computeMapping(controller);
      await _lockCamera(controller);
      await controller.startImageStream(_onImage);
      _running = true;
      notifyListeners();
      _emit('Камера запущена: ${description.name}, ${controller.value.previewSize}, turns=${mapping.quarterTurns}', isError: false);
    } on CameraException catch (e) {
      await _teardown();
      _emit('Камера: ${e.code} ${e.description}', isError: true);
      rethrow;
    } catch (e) {
      await _teardown();
      _emit('Камера: $e', isError: true);
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    await _teardown();
    _running = false;
    notifyListeners();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _teardown();
    await _frames.close();
    await _status.close();
    super.dispose();
  }

  /// Освобождает контроллер. Вызывается и при stop(), и при ошибке — повторный
  /// start() создаёт новый контроллер, без перезапуска приложения.
  Future<void> _teardown() async {
    final CameraController? controller = _controller;
    _controller = null;
    _running = false;
    if (controller == null) {
      return;
    }
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } on CameraException catch (e) {
      _emit('Не удалось остановить поток: ${e.code}', isError: false);
    }
    try {
      await controller.dispose();
    } on CameraException catch (e) {
      _emit('Не удалось освободить камеру: ${e.code}', isError: false);
    }
  }

  Future<void> _lockCamera(CameraController controller) async {
    await _try('вспышка off', () => controller.setFlashMode(FlashMode.off));
    await _try('фокус auto', () => controller.setFocusMode(FocusMode.auto));
    await _try('экспозиция auto', () => controller.setExposureMode(ExposureMode.auto));
    await Future<void>.delayed(options.lockSettle);
    final bool focusLocked = await _try('фокус locked', () => controller.setFocusMode(FocusMode.locked));
    final bool exposureLocked = await _try(
      'экспозиция locked',
      () => controller.setExposureMode(ExposureMode.locked),
    );
    if (!focusLocked || !exposureLocked) {
      final List<String> failed = <String>[
        if (!focusLocked) 'фокус',
        if (!exposureLocked) 'экспозицию',
      ];
      _emit(
        'Плагин camera не дал зафиксировать ${failed.join(' и ')} — возможен дрейф baseline. '
        'Нужен нативный слой (Kotlin/Swift).',
        isError: false,
      );
    }
  }

  /// Возвращает true, если операция удалась. Ошибку устройства не считаем
  /// фатальной: приложение должно продолжать работать.
  Future<bool> _try(String label, Future<void> Function() action) async {
    try {
      await action();
      return true;
    } on CameraException catch (e) {
      _emit('$label не поддерживается: ${e.code}', isError: false);
      return false;
    }
  }

  ImageFormatGroup _defaultFormatGroup() => switch (defaultTargetPlatform) {
    TargetPlatform.android => ImageFormatGroup.yuv420,
    TargetPlatform.iOS => ImageFormatGroup.bgra8888,
    _ => ImageFormatGroup.unknown,
  };

  /// Image stream приходит в ориентации сенсора; превью повёрнуто под
  /// ориентацию устройства. Считаем, на сколько повернуть ROI, чтобы оно
  /// попало в те же пиксели: превью -> кадр = против часовой на sensorOrientation,
  /// то есть (4 - sensorOrientation/90) поворотов по часовой.
  FrameMapping _computeMapping(CameraController controller) {
    final int sensorTurns = (controller.description.sensorOrientation ~/ 90) % 4;
    return FrameMapping(
      quarterTurns: (4 - sensorTurns) % 4,
      mirrorHorizontal: controller.description.lensDirection == CameraLensDirection.front,
    );
  }

  void _onImage(CameraImage image) {
    if (!_running || _frames.isClosed) {
      return;
    }
    final RawLampFrame? frame = _toRawFrame(image);
    if (frame != null) {
      _frames.add(frame);
    }
  }

  RawLampFrame? _toRawFrame(CameraImage image) {
    switch (image.format.group) {
      case ImageFormatGroup.yuv420:
        return RawLampFrame(
          receivedAt: DateTime.now(),
          width: image.width,
          height: image.height,
          format: PixelFormatKind.yuv420,
          luma: image.planes.first.bytes,
          lumaStride: image.planes.first.bytesPerRow,
          chromaU: image.planes.length > 1 ? image.planes[1].bytes : null,
          chromaV: image.planes.length > 2 ? image.planes[2].bytes : null,
          chromaStride: image.planes.length > 1 ? image.planes[1].bytesPerRow : null,
          chromaPixelStride: image.planes.length > 1 ? (image.planes[1].bytesPerPixel ?? 1) : null,
          exposureTimeNs: image.sensorExposureTime,
          sensorSensitivity: image.sensorSensitivity,
        );
      case ImageFormatGroup.bgra8888:
        return RawLampFrame(
          receivedAt: DateTime.now(),
          width: image.width,
          height: image.height,
          format: PixelFormatKind.bgra8888,
          pixels: image.planes.first.bytes,
          pixelStride: image.planes.first.bytesPerPixel ?? 4,
          rowStride: image.planes.first.bytesPerRow,
          exposureTimeNs: image.sensorExposureTime,
          sensorSensitivity: image.sensorSensitivity,
        );
      case ImageFormatGroup.nv21:
      case ImageFormatGroup.jpeg:
      case ImageFormatGroup.unknown:
        // Разрешение формата не то, что запрошено: не спамим в ошибки каждым
        // кадром, но один раз на формат сообщаем.
        if (_unsupportedFormatWarnings++ < 1) {
          _emit(
            'Неподдерживаемый формат кадра ${image.format.group} (${image.format.raw}). '
            'Нужен yuv420 (Android) или bgra8888 (iOS).',
            isError: true,
          );
        }
        return null;
    }
  }

  void _emit(String message, {required bool isError}) {
    if (_status.isClosed) {
      return;
    }
    _status.add(FrameSourceStatus(message, isError: isError));
  }
}

/// Превью камеры для демо. Возвращается пакетом, чтобы example не зависел от
/// плагина `camera`.
class LampCameraPreview extends StatelessWidget {
  const LampCameraPreview({required this.source, super.key});

  final CameraFrameSource source;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: source,
      builder: (BuildContext context, Widget? child) {
        return _CameraPreviewForController(controller: source._controller);
      },
    );
  }
}

class _CameraPreviewForController extends StatelessWidget {
  const _CameraPreviewForController({required this.controller});

  final CameraController? controller;

  @override
  Widget build(BuildContext context) {
    final CameraController? value = controller;
    if (value == null || !value.value.isInitialized) {
      return const ColoredBox(color: Color(0xFF202020), child: Center());
    }
    return CameraPreview(value);
  }
}
