# lamp_detection

Flutter-пакет для счёта попаданий по двум сигнальным лампам — **белой** и **красной** —
через камеру телефона или планшета. Кадр → признаки → гистерезисный детектор → автомат
попаданий → SQLite → очередь доставки на сервер. Работает офлайн: недоставанные события
уходят при следующем запуске, дубли отсекает `PRIMARY KEY`.

Пакет не содержит UI и не знает про конкретный сервер: приложение получает
`Stream<HitEvent>` и решает, что с ними делать.

## Словарь и как это работает

### Термины
- **Кадр (frame)** — одно изображение с камеры, ~30 раз в секунду.
- **ROI (рамка, region of interest)** — прямоугольник-зона. Их две: `white` и `red`
  (`LampRoi`, нормализованные координаты 0..1). Всё считается только внутри рамок.
- **Признак (feature)** — число из пикселей зоны (`FrameFeatures`):
  `meanY` — средняя яркость; `brightFrac` — доля очень светлых пикселей;
  `sat` — насыщенность (насколько цветное, а не серое); `redDom` — краснота
  (`mean(R) − mean((G+B)/2)`); `coreEdgeDiff` — насколько центр ярче кольца.
- **Baseline (фон)** — значения признаков при **выключенных** лампах. Даёт калибровка.
- **Score (оценка)** — одно число по формуле, «насколько похожа вспышка» (`whiteScore` /
  `redScore`).
- **Threshold (порог)** — граница: `score >= threshold` → «горит».
- **Гистерезис** — разные пороги включения/выключения (`offRatio`) плюс подтверждение
  `onConfirmFrames` / `offConfirmFrames` кадров подряд, чтобы одиночный шум не дал события.
- **Состояние (state)** — `ON` / `OFF` / неоднозначное.
- **Hit (попадание, вспышка)** — подтверждённый переход `OFF → ON`. Именно это считаем.

### Что мы реально ловим и в чём сложность
Мы ищем **короткое изменение признака внутри зоны относительно фона**, а не «стало
светло». Сложность не в том, чтобы заметить вспышку, а чтобы **не принять за неё** всё
остальное: смену освещения в комнате, выход солнца, сдвиг/тряску камеры, блик, засветку
окна или экрана, и **отсвет соседней лампы** (красная вспыхнула — красный свет лёг в
белую рамку). Отсюда три защитных механизма: **калибровка** (меряем изменение, а не
абсолют), **гистерезис** (не верить одному кадру) и **цвет как фильтр** (не считать
чужую вспышку своей).

### Как лампа «узнаётся» — не по цвету, а по рамке
Детектор **не распознаёт лампы как объекты**. «Белая это или красная» определяется тем,
**в какой рамке** случилось событие. Если пользователь вручную положил белую рамку на
белую лампу, а красную — на красную, идентификация уже корректна и цвет для неё не нужен.

Но **признак внутри рамки должен быть тот, что у этой лампы реально прыгает**:
- **белая** вспышка = сильный скачок **яркости** → мерим `meanY` / `brightFrac`;
- **красная** вспышка почти **не меняет яркость** (красный даёт мало в BT.601), но сильно
  меняет **красноту** (`redDom`: фон ~23 → вспышка ~130) → её надо мерить по `redDom`.

Поэтому наивное «ловим просто яркостную вспышку» работает для белой, но **пропускает
красную**. Это ключ к подбору формул (см. «Оценка»).

### Алгоритм по шагам (на каждом кадре)
1. `FeatureExtractor` по подвыборке считает признаки в каждой ROI → `FrameFeatures`.
2. `LampDetector` по формулам из `LampConfig` превращает признаки в `whiteScore` /
   `redScore` — **относительно baseline** (калибровки).
3. Сравнение с порогом + гистерезис: нужен `onConfirmFrames` подряд выше ON, чтобы
   состояние стало `ON`, и `offConfirmFrames` ниже OFF-порога, чтобы стало `OFF`.
4. Неоднозначный кадр (обе выше ON) — побеждает бо́льший `score/порог`, проигравший
   в этом кадре нейтрален (не подтверждает чужую вспышку).
5. `HitStateMachine`: переход `OFF → ON` = **одно новое `HitEvent`**; пока лампа горит —
   новых событий нет. `detectedAt` берётся из времени кадра-кандидата.
6. Событие пишется в SQLite (`pending`), затем уходит в `session.hits` и очередь доставки.

## Конвейер

```
FrameSource  ──►  RawLampFrame           camera_frame_source.dart / frame_source.dart
                        │
                FeatureExtractor          detection/feature_extractor.dart
                        ▼                 ROI → FrameFeatures по подвыборке
                   LampFrame
                        │
                  LampDetector            detection/lamp_detector.dart
                        ▼                 whiteScore / redScore, гистерезис ON/OFF
                LampEvaluation
                        │
                HitStateMachine           detection/hit_state_machine.dart
                        ▼                 0..1 HitEvent на кадр
                 EventRepository  ──►  HitEventSender
                (SQLite, offline)          (mock / HTTP)

                        DetectionSession  session/detection_session.dart
                        (оркестратор, ChangeNotifier, единая точка входа)
```

## Публичный API

Импортируйте **только** `package:lamp_detection/lamp_detection.dart`. Он реэкспортирует:

| Группа | Типы |
|---|---|
| Сессия | `DetectionSession`, `LampStatus`, `SettingsStore` |
| Источник кадров | `FrameSource`, `FrameMappingControl`, `CameraFrameSource`, `CameraSourceOptions`, `RawLampFrame`, `FrameSourceStatus`, `PixelFormatKind` |
| Модель | `LampConfig`, `LampRoi`, `RoiLayout`, `FrameMapping`, `FrameFeatures`, `LampFrame`, `LampBaseline`, `HitEvent`, `HitColor` |
| Детекция | `FeatureExtractor`, `LampDetector`, `LampEvaluation`, `HitStateMachine`, `LampSessionState`, `CalibrationProgress` |
| Хранилище | `EventRepository`, `SqliteEventRepository`, `StoredEvent`, `DeliveryStatus`, `lampDataDirectory` |
| Доставка | `HitEventSender`, `DeliveryResult`, `MockHitEventSender` |
| Диагностика | `DiagnosticsCollector`, `DiagnosticsSnapshot`, `ScorePoint`, `FeatureCsvRecorder`, `FeatureCsv`, `FeatureCsvRow` |

## Быстрый старт

```dart
import 'package:lamp_detection/lamp_detection.dart';

final directory = await lampDataDirectory();           // приватный каталог sqflite
final session = DetectionSession(
  source: CameraFrameSource(),
  repository: SqliteEventRepository(
    fileName: SqliteEventRepository.defaultFileName,
    directory: directory.path,
  ),
  sender: MockHitEventSender(),                        // сюда — ваш HTTP/WebSocket
  settings: await SettingsStore.open(),
  csvRecorder: FeatureCsvRecorder(directory: directory),
);

await session.loadSettings();                          // ROI, baseline, config, sessionId
session.hits.listen((e) => print('hit: $e'));
session.errors.listen((m) => print('error: $m'));
session.addListener(() {/* перерисовать UI */});

await session.start();                                 // подписка + камера
if (!session.isCalibrated) {
  await session.calibrate();                           // «обе выключены», 30 кадров
}
```

`session.dispose()` освобождает камеру, закрывает CSV-поток и Completer'ы. Повторный
`start()` работает без перезапуска приложения.

## ROI и ориентация

`LampRoi` задаётся в нормализованных координатах `0..1` от области превью — переживает
смену разрешения и поворота. `RoiLayout.defaults` — стартовая раскладка с реальной записи
(белая лампа сверху, красная снизу слева).

`FeatureExtractor` переводит ROI из координат превью в координаты бай буфера кадра через
`FrameMapping`: плагин `camera` отдаёт image stream в ориентации сенсора, превью
повёрнуто под ориентацию устройства, фронталка зеркалится. Если авто-расчёт по
`sensorOrientation` не угадал на конкретном телефоне — `session.setFrameMapping(turns, mirror: ...)`
(в демо это кнопка «Поворот ROI 90°»).

## Признаки кадра (`FrameFeatures`)

`FeatureExtractor` обходит каждый `subsampleStep`-й пиксель (по x и y) ROI и считает
пять величин. Ни декодирования видео, ни внешних библиотек — только арифметика по байтам.

| Поле | Формула | Диапазон | Зачем |
|---|---|---|---|
| `meanY` | среднее Y: BT.601 из YUV420 либо `0.299R+0.587G+0.114B` из BGRA8888 | 0..255 | базовая яркость ROI |
| `brightFrac` | доля пикселей, где `Y >= brightY` | 0..1 | основа `whiteScore` |
| `sat` | среднее `(max(R,G,B) − min(R,G,B)) / max(R,G,B)` | 0..1 | фильтр «не белая ли это подсветка» |
| `redDom` | `mean(R) − mean((G+B)/2)` | ~ −255..255 | диагностика: красная ROI должна быть красной |
| `coreEdgeDiff` | `meanY(центр) − meanY(кольцо)`, ядро = сторона `coreSideRatio` от ROI | −255..255 | вспышка ярче по центру |

YUV читается с учётом row/pixel stride. Если `yuvFullRange == false`, студийный диапазон
Y 16..235 растягивается в 0..255.

## Оценка (`LampDetector`)

Формулы — **только** из `LampConfig`, магических чисел в коде нет.

- `whiteScore = brightFrac`, если `sat <= whiteSatMax`, иначе `0`.
  Это отсекает ситуацию, когда белая ROI освещена красной лампой: яркость есть,
  но насыщенность высокая — белая не срабатывает.
- `redScore = (red.redDom − baseline.red.redDom) / redDeltaDivisor`.
  Красная считается по **красноте**, а не по яркости: красная вспышка почти не
  меняет `meanY`, но сильно поднимает `redDom`, а белая вспышка `redDom` не
  поднимает — поэтому красная рамка не срабатывает на белую. `coreEdgeDiff`
  в решение **не** входит: при ходу камеры центр рамки каждый кадр разный, и это
  только шумит (величина осталась лишь как сырая диагностика в CSV).
- ON: `score >= onThreshold`. OFF: `score < onThreshold * offRatio` — гистерезис.
- Подтверждение: `onConfirmFrames` / `offConfirmFrames` кадров подряд, иначе серия
  сбрасывается.

**Неоднозначный кадр** (обе лампы сразу выше ON) — побеждает больший `score/порог`,
проигравший в этом кадре не считается ни ON, ни OFF (нейтральная зона), чтобы не
подтвердить ложное событие по «чужой» вспышке.

**Скользящее среднее baseline** (`baselineAlpha`) обновляется только когда обе лампы
реально погашены и ни одна не стала кандидатом ON. Это защита от того, чтобы
вспышка не «съела» калибровку.

## Автомат попаданий (`HitStateMachine`)

Подтверждённое включение = **новое** событие. Правила:

| Переход | Событие |
|---|---|
| `IDLE → WHITE_ON` / `IDLE → RED_ON` | одно новое `HitEvent` |
| `WHITE_ON → WHITE_ON` (лампа горит хоть 3 секунды) | нет |
| `WHITE_ON → IDLE` (подтверждённое выключение) | нет |
| `WHITE_ON → RED_ON` без паузы | второе событие, первое уже записано |

Поле `HitEvent.detectedAt` берётся **не из момента сохранения**, а из времени кадра,
в котором лампа впервые стала кандидатом ON. Это даёт честную задержку «удар →
вспышка → событие» даже при подтверждении в 2..3 кадра.

События нумеруются с 1 в рамках `sessionId` (UUID v4). Новая сессия обнуляет и
нумерацию, и состояние автомата.

## Калибровка «обе выключены»

`session.calibrate()` набирает `calibrationFrames` (по умолчанию 30) кадров с погашенными
лампами, усредняет признаки каждой ROI и сохраняет `LampBaseline`. `isCalibrated` становится
true. `session.stop()` пишет baseline в `SettingsStore`, следующий запуск стартует уже
откалиброванным.

Панорамирование рукой во время калибровки портит baseline: если в кадр при калибровке
попал красный объект, `baseline.red.redDom` завышается, и реальные вспышки становятся
слабее относительно него. Калибруйте на штативе или держите телефон неподвижно, направляя
рамку красной именно на красную лампу при обеих выключенных.

## Хранилище (`SqliteEventRepository`)

Таблица `hit_events`:

```
event_id           TEXT PRIMARY KEY      -- uuid v4, защита от дублей
session_id         TEXT NOT NULL
lamp_id            TEXT NOT NULL         -- 'white' | 'red'
color              TEXT NOT NULL
detected_at_ms     INTEGER NOT NULL
sequence_number    INTEGER NOT NULL
delivery_status    TEXT NOT NULL         -- pending | sent | failed
attempts           INTEGER NOT NULL DEFAULT 0
last_attempt_at_ms INTEGER
```

Индексы: `(session_id, sequence_number)`, `(delivery_status)`. `save` идёт с
`ConflictAlgorithm.ignore` — повторная вставка того же `eventId` ничего не ломает.

Событие сначала пишется в SQLite, и только потом попадает в `session.hits` и в очередь
доставки. Приложение может упасть между этими шагами — событие не потеряется.

## Доставка (`HitEventSender`)

Интерфейс из одного метода. В MVP есть `MockHitEventSender` с флагом `offline` и
настраиваемой задержкой — он позволяет показать работу pending-очереди без сервера.
Реальный HTTP или WebSocket подключается заменой одного класса, пакет править не нужно.

`DetectionSession._deliverLoop` отправляет строго последовательно: при первом же
неуспехе цикл встаёт, событие получает статус `failed` и `attempts + 1`, остальные
ждут следующего `deliverPending()`. `session.start()` вызывает его автоматически.

## Диагностика

`DiagnosticsCollector` считает:

- `cameraFps`, `analysisFps` по скользящему окну (по умолчанию 60 кадров),
- `avgAnalysisMs` / `maxAnalysisMs` (`beginAnalysis` / `endAnalysis`),
- `droppedFrames` — сколько кадров пришло, пока обработчик был занят,
- `avgSaveLatencyMs` / `maxSaveLatencyMs` — задержка обнаружение → SQLite,
- `eventCount`, `ambiguousFrames`,
- `exposureTimeNs` / `sensorSensitivity` последнего кадра — если дрейфуют, авто-
  экспозиция не зафиксирована и baseline будет плыть,
- `needsIsolate` — `avgAnalysisMs > analysisIsolateThresholdMs` (8 мс по умолчанию);
  в MVP перенос анализа в isolate не реализован, флаг только подсказывает.

`DetectionSession.scoreHistory` отдаёт список `ScorePoint` для графика: по этой истории
видно, меняется ли `redScore` при повторном ударе, пока лампа ещё горит.

## CSV-запись и воспроизведение

`FeatureCsvRecorder` пишет по строке на кадр:

```
timestamp_ms, white_meanY, white_brightFrac, white_sat,
red_meanY, red_redDom, red_coreEdgeDiff, state
```

Белая часть не содержит `redDom` и `coreEdgeDiff`, красная — `brightFrac` и `sat`:
эти величины не участвуют в формулах `whiteScore` / `redScore`, поэтому при
воспроизведении они равны 0 и CSV остаётся компактным.

`DetectionSession.replayCsv(csv, baseline: ...)` прогоняет файл через тот же
`LampDetector` и тот же `HitStateMachine` — без камеры, без isolate, полностью
детерминированно. Если baseline не передан, первые `calibrationFrames` строк
усредняются как калибровка (так CSV и пишется: сначала кадры с выключенными лампами).
Это основной инструмент подбора порогов по реальным записям.

## Демо-приложение

`example/` — полный экран для подбора порогов на реальном железе:

- превью с перетаскиваемыми ROI (жест за центр — двигать, за угол — размер);
- кнопки: Start / Stop / Калибровка / CSV / Новая сессия / Reset счётчиков /
  Поворот ROI 90° / Сеть (переключает `MockHitEventSender.offline`);
- статус ON/OFF и счётчики WHITE/RED HITS;
- график `whiteScore` / `redScore`, нормированный на ON-порог (линия y = 1);
- вкладки **Журнал** (события + статусы доставки из SQLite), **Диагностика**
  (`DiagnosticsSnapshot` + ROI + baseline + путь к CSV), **Ошибки**.

Как запустить и настроить — см. `example/README.md`.

## Известные ограничения

- **`camera` 0.12 не отдаёт метку кадра.** `LampFrame.timestamp` = время прихода кадра
  в image stream (`DateTime.now()` в колбэке плагина), а не время экспозиции. Это
  стабильно в пределах устройства, но не синхронизировано с сервером по UTC.
- **Панорамирование рукой** сдвигает baseline (в т.ч. `redDom`) и может как занизить,
  так и ложно поднять `redScore` — пороги подобраны под штатив / закреплённый телефон.
- **Автоэкспозиция**: `CameraFrameSource` после `lockSettle` пытается зафиксировать
  AE/AWB, но не на всех устройствах это получается. Следите за `exposureTimeNs` и
  `sensorSensitivity` во вкладке «Диагностика».
- **Изолят**: перенос `FeatureExtractor` в `Isolate` в MVP не сделан. Если
  `needsIsolate == true`, анализ кадра слишком медленный для этого устройства —
  увеличьте `subsampleStep` или понижайте `resolutionPreset`.

## Тесты

`test/hit_detection_test.dart` — синтетические сценарии на базе `Scene`
(`test/support/synthetic_scene.dart`): тёмная подставка, пересвет белой, рост
`meanY` + `coreEdgeDiff` у красной, белая ROI под подсветкой красной. Проверяют
формулы `whiteScore` / `redScore`, гистерезис ON/OFF, поведение при неоднозначном
кадре, правило «одно событие на переход», восстановление baseline из настроек и
что `HitEvent.detectedAt` = время кадра-кандидата.

```
flutter test
```
