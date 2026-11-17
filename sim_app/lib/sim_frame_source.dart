import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:lamp_detection/lamp_detection.dart';

/// Какое состояние лампы сейчас «на экране» симулятора.
enum SimScene { off, white, red }

/// Разобранный PNG: байты для детектора + картинка для превью.
class _DecodedImage {
  _DecodedImage(this.image, this.pixels, this.width, this.height);

  final ui.Image image;

  /// Уже в порядке BGRA, как ожидает FeatureExtractor (PixelFormatKind.bgra8888).
  final Uint8List pixels;
  final int width;
  final int height;
}

/// Источник кадров из трёх статичных картинок, без камеры.
///
/// Кормит реальный пайплайн (`FeatureExtractor` → `LampDetector` →
/// `HitStateMachine`) кадрами, где «съёмка» — это переключение между off / white /
/// red. Нужен, чтобы тестировать детекцию, пока нет настоящих ламп.
///
/// ROI в этом режиме — весь кадр: кадр целиком и есть «лампа», поэтому рамки не
/// перетаскиваются (см. RoiLayout в home_page).
class SimFrameSource extends ChangeNotifier implements FrameSource {
  SimFrameSource({this.frameInterval = const Duration(milliseconds: 33)});

  /// Темп «видеопотока»: 30 fps по умолчанию.
  final Duration frameInterval;

  final StreamController<RawLampFrame> _frames = StreamController<RawLampFrame>.broadcast();
  final StreamController<FrameSourceStatus> _status = StreamController<FrameSourceStatus>.broadcast();

  final Map<SimScene, _DecodedImage> _images = <SimScene, _DecodedImage>{};
  SimScene _scene = SimScene.off;
  Timer? _timer;
  bool _running = false;
  bool _ready = false;

  SimScene get scene => _scene;
  bool get isReady => _ready;

  /// Картинка текущей сцены для превью (null до [load]).
  ui.Image? get currentImage => _images[_scene]?.image;

  /// Загружает и декодирует три asset-картинки. Вызывать до [start].
  Future<void> load() async {
    _images[SimScene.off] = await _decode('assets/off.png');
    _images[SimScene.white] = await _decode('assets/white.png');
    _images[SimScene.red] = await _decode('assets/red.png');
    _ready = true;
    notifyListeners();
  }

  Future<_DecodedImage> _decode(String asset) async {
    final ByteData data = await rootBundle.load(asset);
    final ui.Codec codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final ui.FrameInfo frame = await codec.getNextFrame();
    final ui.Image image = frame.image;
    final ByteData? rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final Uint8List bytes = rgba!.buffer.asUint8List();
    // rawRgba даёт порядок R,G,B,A — а детектор ждёт B,G,R,A. Меняем R и B местами.
    for (int i = 0; i + 3 < bytes.length; i += 4) {
      final int r = bytes[i];
      bytes[i] = bytes[i + 2];
      bytes[i + 2] = r;
    }
    return _DecodedImage(image, bytes, image.width, image.height);
  }

  /// Меняет показываемую сцену. Работает и на лету, и во время авто-цикла.
  void setScene(SimScene scene) {
    if (_scene == scene) {
      return;
    }
    _scene = scene;
    notifyListeners();
  }

  @override
  Stream<RawLampFrame> get frames => _frames.stream;

  @override
  Stream<FrameSourceStatus> get status => _status.stream;

  @override
  bool get isRunning => _running;

  @override
  Size? get previewSize {
    final _DecodedImage? img = _images[_scene];
    return img == null ? null : Size(img.width.toDouble(), img.height.toDouble());
  }

  @override
  FrameMapping get mapping => FrameMapping.identity;

  @override
  Widget buildPreview() => _SimPreview(source: this);

  @override
  Future<void> start() async {
    if (_running) {
      return;
    }
    if (!_ready) {
      _status.add(const FrameSourceStatus('Картинки ещё не загружены'));
      return;
    }
    _running = true;
    _timer = Timer.periodic(frameInterval, (_) => _emit());
    _status.add(const FrameSourceStatus('Симулятор запущен', isError: false));
  }

  @override
  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  void _emit() {
    if (_frames.isClosed) {
      return;
    }
    final _DecodedImage? img = _images[_scene];
    if (img == null) {
      return;
    }
    _frames.add(
      RawLampFrame(
        receivedAt: DateTime.now(),
        width: img.width,
        height: img.height,
        format: PixelFormatKind.bgra8888,
        pixels: img.pixels,
        pixelStride: 4,
        rowStride: img.width * 4,
      ),
    );
  }

  @override
  Future<void> dispose() async {
    await stop();
    for (final _DecodedImage img in _images.values) {
      img.image.dispose();
    }
    _images.clear();
    await _frames.close();
    await _status.close();
    super.dispose();
  }
}

/// Превью: текущая картинка симулятора, перерисовывается при смене сцены.
class _SimPreview extends StatelessWidget {
  const _SimPreview({required this.source});

  final SimFrameSource source;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: source,
      builder: (BuildContext context, Widget? child) {
        final Size? size = source.previewSize;
        if (size == null || !source.isReady) {
          return const ColoredBox(color: Color(0x1FFFFFFF));
        }
        return CustomPaint(
          painter: _ImagePainter(source),
          size: size,
        );
      },
    );
  }
}

class _ImagePainter extends CustomPainter {
  _ImagePainter(this.source);

  final SimFrameSource source;

  @override
  void paint(Canvas canvas, Size size) {
    // Рисуем текущую сцену через ui.Image. Source хранит картинку по сцене.
    final ui.Image? image = source.currentImage;
    if (image == null) {
      return;
    }
    final Rect dst = Offset.zero & size;
    paintImage(canvas: canvas, rect: dst, image: image, fit: BoxFit.cover);
  }

  @override
  bool shouldRepaint(_ImagePainter old) => old.source.scene != source.scene;
}
