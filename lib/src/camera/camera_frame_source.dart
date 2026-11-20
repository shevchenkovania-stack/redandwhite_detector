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
class CameraFrameSource extends ChangeNotifier
    implements FrameSource, FrameMappingControl, ExposureControl {
  CameraFrameSource({this.options = const CameraSourceOptions()});

  final CameraSourceOptions options;

  /// Сколько ждём блокировку фокуса/экспозиции. Внутри `_lockCamera` ещё и
  /// `lockSettle` на сходимость, поэтому запас взят с ним в одном порядке.
  static const Duration _lockBudget = Duration(seconds: 10);

  final StreamController<RawLampFrame> _frames = StreamController<RawLampFrame>.broadcast();
  final StreamController<FrameSourceStatus> _status = StreamController<FrameSourceStatus>.broadcast();

  CameraController? _controller;
  bool _running = false;
  bool _disposed = false;
  bool _exposureLocked = false;

  /// Текущее смещение экспозиции в EV. Плагин наружу его не отдаёт.
  double _exposureOffsetEv = 0;
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
      // Порядок важен: лок ставится ПОСЛЕ startImageStream. Плагин `camera` на
      // Android при привязке повторного запроса к потоку перепривязывает
      // CameraX, и зафиксированная заранее экспозиция возвращается в auto —
      // детектор же этот возврат читает как вспышку лампы.
      await controller.startImageStream(_onImage);
      _running = true;
      notifyListeners();
      // Кадры уже идут, поэтому ждать фиксации света вечно нельзя: на части
      // устройств `setExposureMode`/`setFocusMode` не отвечает никогда, и старт
      // зависал навсегда при работающей камере (первый запуск 20.11.2026).
      // Не запертый свет — ухудшение точности, а не отказ приложения.
      await _lockCamera(controller).timeout(
        _lockBudget,
        onTimeout: () => _emit(
          'Фиксация экспозиции не ответила за ${_lockBudget.inSeconds} с — '
          'работаю с автоэкспозицией',
          isError: false,
        ),
      );
      _emit('Камера запущена: ${description.name}, ${controller.value.previewSize}, turns=${mapping.quarterTurns}, экспозиция ${_exposureLocked ? "зафиксирована" : "НЕ зафиксирована"}', isError: false);
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
    _exposureLocked = false;
    _exposureOffsetEv = 0;
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
    _exposureLocked = await _try(
      'экспозиция locked',
      () => controller.setExposureMode(ExposureMode.locked),
    );
    if (!focusLocked || !_exposureLocked) {
      final List<String> failed = <String>[
        if (!focusLocked) 'фокус',
        if (!_exposureLocked) 'экспозицию',
      ];
      _emit(
        'Плагин camera не дал зафиксировать ${failed.join(' и ')} — возможен дрейф baseline. '
        'Нужен нативный слой (Kotlin/Swift).',
        isError: false,
      );
    }
  }

  /// Отпускает автоэкспозицию, даёт сенсору сойтись и снова запирает её.
  ///
  /// Вызывается перед каждым шагом калибровки: лампу включают рукой, и
  /// автоэкспозиция за этот момент успевает уехать на несколько стоп-экспозиций.
  /// Если её не запереть, шаг «белая горит» набирается на одном свете, а
  /// рабочее событие — на другом, и один и тот же удар лампы считается дважды.
  @override
  Future<void> relockExposure() async {
    final CameraController? controller = _controller;
    if (!_running || controller == null || !controller.value.isInitialized) {
      return;
    }
    if (!await _try('экспозиция auto', () => controller.setExposureMode(ExposureMode.auto))) {
      return;
    }
    await Future<void>.delayed(options.lockSettle);
    if (!_running) {
      // «Стоп» нажали, пока сенсор сходился: дальше дергать контроллер нельзя.
      return;
    }
    _exposureLocked = await _try(
      'экспозиция locked',
      () => controller.setExposureMode(ExposureMode.locked),
    );
  }

  @override
  bool get exposureLocked => _exposureLocked;

  /// Уводит экспозицию на шаг вниз (≈2× темнее) и запирает снова. Нужен при
  /// пересвете: в клиппинге яркость и цвет теряются одновременно, и рамка
  /// белой лампы становится слепой.
  @override
  Future<bool> reduceExposure() async {
    final CameraController? controller = _controller;
    if (!_running || controller == null || !controller.value.isInitialized) {
      return false;
    }
    try {
      await controller.setExposureMode(ExposureMode.auto);
      final double min = await controller.getMinExposureOffset();
      final double step = await controller.getExposureOffsetStepSize();
      // `camera` 0.12 текущее смещение экспозиции наружу не отдаёт, поэтому он
      // помнит его сам: без этого второй вызов уводил бы не «ещё на шаг», а
      // снова от нуля.
      final double target = (_exposureOffsetEv - (step > 0 ? step : 0.3))
          .clamp(min, double.maxFinite)
          .toDouble();
      _exposureOffsetEv = await controller.setExposureOffset(target);
      _emit('Экспозиция убавлена до $_exposureOffsetEv EV (пересвет)', isError: false);
    } on CameraException catch (e) {
      _emit('Убрать экспозицию не вышло: ${e.code}', isError: false);
      return false;
    } on Object catch (e) {
      // StateError освобождённого контроллера сюда приходит, а не в
      // Unhandled Exception: камеру могли закрыть во время паузы на сходимость.
      _emit('Убрать экспозицию не вышло: $e', isError: false);
      return false;
    }
    await Future<void>.delayed(options.lockSettle);
    if (!_running) {
      return false;
    }
    _exposureLocked = await _try(
      'экспозиция locked',
      () => controller.setExposureMode(ExposureMode.locked),
    );
    return true;
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
    } on Object catch (e) {
      // Камеру освободили, пока операция ждала очереди: плагин кидает
      // StateError («CameraController was used after being disposed»), и вне
      // этой ветки он улетал в Unhandled Exception — в логе это выглядело как
      // падение калибровки, хотя калибровка к нему непричастна.
      _emit('$label: $e', isError: false);
      return false;
    }
  }

  ImageFormatGroup _defaultFormatGroup() => switch (defaultTargetPlatform) {
    TargetPlatform.android => ImageFormatGroup.yuv420,
    TargetPlatform.iOS => ImageFormatGroup.bgra8888,
    _ => ImageFormatGroup.unknown,
  };

  /// Image stream приходит в ориентации сенсора, а превью плагин поворачивает на
  /// sensorOrientation ПО ЧАСОВОЙ. Значит от превью к пикселям кадра надо
  /// повернуть на столько же поворотов [FrameMapping.toFrame], то есть ровно
  /// sensorOrientation/90 — а не (4 - sensorOrientation/90), как было раньше.
  ///
  /// Проверено на живом устройстве (Pixel 8 Pro, sensorOrientation=90): дамп
  /// кадра 720x480 и скриншот превью. Рамка, нарисованная на белой лампе, при
  /// turns=3 попадала в тёмный фон (wf=0.18 в дампе против 0.97 на экране), при
  /// turns=1 — ровно в колпак (wf=0.88). Формула «4 - turns» давала 3.
  ///
  /// Ориентацию устройства здесь сознательно НЕ учесть: на экране в ландшафте
  /// превью доворачивается, и рамка начнёт sampling не той четверти кадра.
  /// Проверено только в портрете; пока не измерено на живой лампе, остаётся
  /// ручное «Поворот ROI 90°».
  FrameMapping _computeMapping(CameraController controller) {
    final int sensorTurns = (controller.description.sensorOrientation ~/ 90) % 4;
    return FrameMapping(
      quarterTurns: sensorTurns,
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
