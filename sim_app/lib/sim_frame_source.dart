import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:lamp_detection/lamp_detection.dart';

/// Какое состояние лампы сейчас «на экране» симулятора.
///
/// `both` — обе горят одновременно. В цикле и в ручном режиме такой сцены нет:
/// настоящие лампы одновременно не загораются. Сцена осталась только как
/// лабораторный стимул — проверить, что каналы детекции не гасят друг друга.
enum SimScene { off, white, red, both }

/// Каким набором картинок мигает панель.
///
/// [drawn] — нарисованные колпаки (`assets/*.png`): идеальная геометрия, чистый
/// сигнал, ни одного лишнего пикселя. Это эталон для проверки **тайминга**.
///
/// [photo] — настоящий свет (`assets/photo/*.png`): та же нарисованная
/// геометрия, но и свечение, и вид выключенного колпака измерены с фото
/// настоящей лампы. Это проверка **фотометрии** — какие доли пикселей реально
/// даёт лампа вместе со своим ореолом.
enum SimStyle { drawn, photo }

/// Рамки, которые действительно попадают на колпаки картинок панели.
///
/// `RoiLayout.defaults` описывает живую запись с телефона и к этим картинкам
/// не относится: белая рамка там начинается с 0.38, а белый колпак нарисован
/// на 0.289–0.550; красная рамка стоит на 0.10–0.44, а красный колпак — на
/// 0.446–0.753. Считать по дефолтным рамкам — значит мерить фон и сравнивать
/// два способа измерения фона, поэтому для прогонов по картинкам берутся эти.
///
/// Границы сняты с самих PNG (доли ширины и высоты кадра 720×1280) и слегка
/// расширены: под пороги «белый/красный» попадает яркое ядро колпака, а сам
/// круг с каймой чуть больше.
const RoiLayout simPictureRoi = RoiLayout(
  white: LampRoi(left: 0.27, top: 0.21, width: 0.30, height: 0.18),
  red: LampRoi(left: 0.43, top: 0.53, width: 0.34, height: 0.21),
);

/// Разобранный PNG: байты для детектора + картинка для превью.
class _DecodedImage {
  _DecodedImage(this.image, this.pixels, this.width, this.height);

  final ui.Image image;

  /// Уже в порядке BGRA, как ожидает FeatureExtractor (PixelFormatKind.bgra8888).
  final Uint8List pixels;
  final int width;
  final int height;
}

/// Картинки состояний лампы для тестовой панели.
///
/// Панель только показывает выбранную сцену ([buildPreview]): детекции здесь
/// нет, счёт ударов делает настоящий пайплайн на камере (`example/`).
/// Интерфейс [FrameSource] реализован на случай прогона пайплайна по
/// синтетическим кадрам — [start] рассылает текущую сцену с темпом
/// [frameInterval]. В текущей сборке [start] не вызывается, кадры не генерируются.
class SimFrameSource extends ChangeNotifier implements FrameSource {
  SimFrameSource({this.frameInterval = const Duration(milliseconds: 33)});

  /// Темп «видеопотока»: 30 fps по умолчанию.
  final Duration frameInterval;

  final StreamController<RawLampFrame> _frames = StreamController<RawLampFrame>.broadcast();
  final StreamController<FrameSourceStatus> _status = StreamController<FrameSourceStatus>.broadcast();

  final Map<SimScene, _DecodedImage> _images = <SimScene, _DecodedImage>{};
  final Map<SimScene, _DecodedImage> _photos = <SimScene, _DecodedImage>{};
  SimScene _scene = SimScene.off;
  SimStyle _style = SimStyle.drawn;
  Timer? _timer;
  bool _running = false;
  bool _ready = false;

  /// Во что умножать RGB **горящей** сцены: 1.0 = как нарисовано в PNG,
  /// 2.5 = очень яркая лампа. На сцене `off` не действует намеренно — иначе
  /// засветился бы фон, калибровка поехала бы, а прирост доли белых/красных
  /// пикселей (то, что считает детектор) почти не изменился.
  double brightness = 1.0;

  /// Смещение картинки в долях её собственной ширины/высоты, [-0.5 .. 0.5].
  double shiftX = 0.0;
  double shiftY = 0.0;

  SimScene get scene => _scene;
  SimStyle get style => _style;
  bool get isReady => _ready;

  /// Фото-набор загружен целиком и в него можно переключаться.
  bool get hasPhotoSet => _photos.length == SimScene.values.length;

  Map<SimScene, _DecodedImage> get _set =>
      _style == SimStyle.photo && hasPhotoSet ? _photos : _images;

  /// Картинка текущей сцены для превью (null до [load]).
  ui.Image? get currentImage => _set[_scene]?.image;

  /// Загружает и декодирует оба набора картинок. Вызывать до [start].
  ///
  /// Фото-набор грузится последним и по ошибке пропускается: без настоящих
  /// ламп панель обязана работать как раньше, а не падать на старте.
  Future<void> load() async {
    _images[SimScene.off] = await _decode('assets/off.png');
    _images[SimScene.white] = await _decode('assets/white.png');
    _images[SimScene.red] = await _decode('assets/red.png');
    _images[SimScene.both] = await _decode('assets/both.png');
    for (final SimScene scene in SimScene.values) {
      try {
        _photos[scene] = await _decode('assets/photo/${scene.name}.png');
      } on Object catch (_) {
        _photos.clear();
        break;
      }
    }
    _ready = true;
    notifyListeners();
  }

  /// Меняет набор картинок. Возвращает false, если фото-набор не загружен:
  /// тогда ничего не происходит, и UI обязан это показать.
  bool setStyle(SimStyle style) {
    if (style == SimStyle.photo && !hasPhotoSet) {
      return false;
    }
    if (_style == style) {
      return true;
    }
    _style = style;
    notifyListeners();
    return true;
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

  /// Яркость и положение картинки. Это только отрисовка: [_emit] отдаёт в
  /// `FrameSource` исходные байты PNG, поэтому синтетический прогон пайплайна
  /// настроек не видит. Реальный детектор смотрит камерой на экран — ему
  /// изменение видно.
  void setView({double? brightness, double? shiftX, double? shiftY}) {
    final double newBrightness = brightness ?? this.brightness;
    final double newShiftX = shiftX ?? this.shiftX;
    final double newShiftY = shiftY ?? this.shiftY;
    if (newBrightness == this.brightness &&
        newShiftX == this.shiftX &&
        newShiftY == this.shiftY) {
      return;
    }
    this.brightness = newBrightness;
    this.shiftX = newShiftX;
    this.shiftY = newShiftY;
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
    final _DecodedImage? img = _set[_scene];
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
    final _DecodedImage? img = _set[_scene];
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
    for (final _DecodedImage img in <_DecodedImage>[
      ..._images.values,
      ..._photos.values,
    ]) {
      img.image.dispose();
    }
    _images.clear();
    _photos.clear();
    await _frames.close();
    await _status.close();
    super.dispose();
  }
}

/// Превью: текущая картинка симулятора с учётом яркости и положения.
class _SimPreview extends StatelessWidget {
  const _SimPreview({required this.source});

  final SimFrameSource source;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: source,
      builder: (BuildContext context, Widget? child) {
        final ui.Image? image = source.currentImage;
        if (image == null || !source.isReady) {
          return const ColoredBox(color: Color(0x1FFFFFFF));
        }
        Widget picture = RawImage(image: image, fit: BoxFit.contain);
        // Сцену «обе выключены» не осветляем: иначе засветится фон, уедет
        // калибровка, а прирост долей пикселей почти не изменится.
        if (source.scene != SimScene.off && source.brightness > 1.0) {
          picture = ColorFiltered(
            colorFilter: _boostFilter(source.brightness),
            child: picture,
          );
        }
        return LayoutBuilder(
          builder: (BuildContext context, BoxConstraints box) {
            // contain, а не cover: при широком окне cover обрезает верх и низ
            // кадра, и колпаки ламп уходят за пределы видимости.
            final Size drawn =
                applyBoxFit(
                  BoxFit.contain,
                  Size(image.width.toDouble(), image.height.toDouble()),
                  Size(box.maxWidth, box.maxHeight),
                ).destination;
            return Align(
              child: Transform.translate(
                offset: Offset(
                  source.shiftX * drawn.width,
                  source.shiftY * drawn.height,
                ),
                child: SizedBox(
                  width: drawn.width,
                  height: drawn.height,
                  child: picture,
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Яркость = умножение RGB на коэффициент. Матричный [ColorFilter] считается
/// на GPU, в отличие от перебора пикселей картинки в Dart.
ColorFilter _boostFilter(double v) => ColorFilter.matrix(<double>[
  v, 0, 0, 0, 0, //
  0, v, 0, 0, 0, //
  0, 0, v, 0, 0, //
  0, 0, 0, 1, 0, //
]);
