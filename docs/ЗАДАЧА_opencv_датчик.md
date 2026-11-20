# ЗАДАЧА: второй измеритель признаков на OpenCV с рубильником Dart/OpenCV

## АКТУАЛЬНО (последняя правка, 20.11.2026)

Пользователь убрал сравнения и описания: в демо ровно **два режима** — меню «1 Считать по Dart» и «2 Только OpenCV». Теневой режим «OpenCV: второй измеритель» и его отчёт из интерфейса удалены (файл `opencv_shadow.dart` остался, но не используется). В режиме 2 OpenCV **строго один**: при отказе измерения кадр становится пустым (`FrameFeatures.zero`), fallback на Dart-экстрактор убран, причина отказа пишется один раз в logcat (`OPENCVSENSOR`). Цветовые доли в OpenCV-режиме не вычисляются Dart-формулой — берётся то, что дал OpenCV, иначе 0; на решение они не влияют. Переключение по-прежнему закрывает/открывает CSV и сбрасывает калибровку. По просьбе пользователя нижняя часть экрана упрощена: удалены баннер «Свет стабилизируется» (`_ReadyBanner`), полоса «1 DART / ЖИВОЙ ПОЛ» (`_ModeStrip`) и надпись «Считаю» внизу (`_nextStepMessage` возвращает пустую строку, когда можно считать). Верх экрана и меню не тронуты.

**Внутренний рабочий файл для продолжения работы (не публичная документация). Обновлено 20.11.2026. Статус: рубильник реализован, ждёт прогона на телефоне** — теневой OpenCV-измеритель, правка пакета, OpenCV-датчик и меню готовы; сборка APK с рубильником идёт, прогоны сравнения не начаты.

**Текущее состояние (проверено):** проект `C:\WORK\FLUTTER\WORK_PROJECTS\redandwhite\lamp_detection` — git-репозиторий (родительская папка `redandwhite` — нет), **ветка `opencv_sensor`** (создана 20.11.2026 без snapshot-коммита: 31 файл WIP перенесён в рабочем дереве, `main` не тронут), последний коммит `2ccfb1b` «v0.1.0: stable build after stand run». Flutter 3.41.4 / Dart 3.11.1, Windows. Pixel 8 Pro `3A191FDJG0021L` подключён, на него установлен APK **с теневой сверкой** (до рубильника). `flutter test` — 63/63 зелёные, `flutter analyze --no-pub` в `example` — No issues found.

## Подзадачи

### Этап 0 — исследование и тень (сделано)

| ID | Подзадача | Статус | Заметка |
|---|---|---|---|
| T0.1 | Выбор библиотеки | СДЕЛАНО | opencv_dart 2.2.2, пребилды Android arm64 |
| T0.2 | Теневой измеритель в example | СДЕЛАНО | `example/lib/opencv_features.dart` (`OpenCvFeatureExtractor`, `measure` → `OpenCvFrameMeasure`), `example/lib/opencv_shadow.dart` (`OpenCvShadowInstrument`), пункт меню «OpenCV: второй измеритель» в `home_page.dart`; паддинг YUV-строк (lumaStride ≠ width) чинится перекладкой в плотный буфер в `_toGray` — в sim_app этой правки нет; отчёт — `lamp_opencv_compare.txt` |
| T0.3 | Зависимости + анализ | СДЕЛАНО | `example/pubspec.yaml`: opencv_dart 2.2.2, ffi ^2.2.0; `flutter pub get` чисто; `flutter analyze --no-pub` — No issues found |
| T0.4 | Сборка app-debug.apk с OpenCV | СДЕЛАНО | APK **не установлен**, 196.3 МБ; внутри `libdartcv.so`: arm64-v8a 10.5 МБ, armeabi-v7a 7.3 МБ, x86_64 14.9 МБ. Сборка один раз падала на залоченном кэше Gradle — вылечено (убиты демоны PID 23424, 9104, 2072, каталог `build` удалён) |
| T0.5 | Исследование архитектуры под рубильник | СДЕЛАНО | См. раздел «Проверенные факты об архитектуре» |

### Этап 1 — сверка на телефоне

| ID | Подзадача | Статус | Заметка |
|---|---|---|---|
| T1.1 | Подключить Pixel, установить APK | СДЕЛАНО | 20.11.2026: Pixel `3A191FDJG0021L` подключён, `adb install -r -d ...app-debug.apk` → Success (APK с теневой сверкой; после сборки рубильника установить заново) |
| T1.2 | Прогон теневой сверки | ОЖИДАЕТ | Последовательность: off → white → off → red → off |
| T1.3 | Снять отчёт, зафиксировать расхождение | ОЖИДАЕТ | Путь отчёта печатается в logcat: «OPENCV отчёт: <path>» |
| T1.4 | Решение по числам сверки | ОЖИДАЕТ | Запись в `docs/ЖУРНАЛ.md` |

### Этап 2 — git-ветка

| ID | Подзадача | Статус | Заметка |
|---|---|---|---|
| T2.1 | Разрешение: коммитить ли WIP снимком перед веткой | СДЕЛАНО | Решение: snapshot-коммит НЕ нужен — ветка создана без коммита, 31 файл WIP перенесён в рабочем дереве, `main` не тронут (Q2 закрыт) |
| T2.2 | Создать ветку | СДЕЛАНО | 20.11.2026: `git checkout -b opencv_sensor`, `git branch --show-current` → `opencv_sensor` |
| T2.3 | Правило отката | СДЕЛАНО | `git checkout main` — все изменения разработки остаются на `opencv_sensor` |

### Этап 3 — правка пакета (`lib/src/session/detection_session.dart`)

| ID | Подзадача | Статус | Заметка |
|---|---|---|---|
| T3.1 | Снять `final` с `_extractor` | СДЕЛАНО | Поле стало `FeatureExtractor _extractor`, конструктор не меняется |
| T3.2 | Сохранить прежний экстрактор в отдельное поле | СДЕЛАНО | `late final FeatureExtractor _dartExtractor`, инициализируется в конструкторе `_dartExtractor = _extractor` |
| T3.3 | Сеттер `sensorExtractor` | СДЕЛАНО | Геттер + сеттер: `null` → `_dartExtractor`, иначе подставленный; свежий получает `_config`, `_notify(force: true)`; пакет не стирает калибровку — это делает демо |
| T3.4 | `flutter test` зелёный | СДЕЛАНО | 20.11.2026: 63/63 теста прошли (`flutter test`) |

### Этап 4 — OpenCV-датчик в demo (`example`)

| ID | Подзадача | Статус | Заметка |
|---|---|---|---|
| T4.1 | `example/lib/opencv_sensor.dart` | СДЕЛАНО | `OpenCvSensorExtractor extends FeatureExtractor`, `extract()` через `OpenCvFeatureExtractor.measure`; при null/исключении — `super.extract()` (Dart) для этого кадра + первая ошибка `OPENCVSENSOR` в лог; `config`-сеттер пробрасывается в OpenCV; `dispose()` освобождает Mat; Q1 решён: YUV-доли — копией BT.601 |
| T4.2 | Пункт меню «Датчик: Dart / OpenCV» | СДЕЛАНО | Пункт `sensor` в popup-меню, обработчик в `_onMenu`; заголовок показывает активный датчик |
| T4.3 | Последовательность переключения | СДЕЛАНО | `_toggleSensor`: CSV stop → смена → `resetCalibration()` → CSV start → сообщение «Датчик: … Калибровка сброшена — жми 1 ФОН» + маркер `SENSOR Dart/OpenCV` в logcat |
| T4.4 | `dispose` при закрытии экрана | СДЕЛАНО | Возврат `sensorExtractor = null`, затем `_sensor.dispose()`; нативный Mat не утекает |
| T4.5 | `flutter analyze` | СДЕЛАНО | 20.11.2026: `flutter analyze --no-pub` в `example` — No issues found |

### Этап 5 — прогоны сравнения и решение

| ID | Подзадача | Статус | Заметка |
|---|---|---|---|
| T5.1 | Прогон на Dart | ОЖИДАЕТ | |
| T5.2 | Прогон на OpenCV | ОЖИДАЕТ | Та же сцена, калибровка заново |
| T5.3 | Сравнение | ОЖИДАЕТ | Попадания / ложные / пропуски, ms/кадр (диагностика beginAnalysis/endAnalysis уже пишет) |
| T5.4 | Решение | ОЖИДАЕТ | Запись в `CHANGELOG.md` |

## Проверенные факты об архитектуре

### Проект, инструменты, состояние

- `C:\WORK\FLUTTER\WORK_PROJECTS\redandwhite\lamp_detection` — git-репозиторий (родительская папка `redandwhite` — нет); ветка `main`, последний коммит `2ccfb1b` «v0.1.0: stable build after stand run».
- Рабочее дерево грязное — пользовательская работа: изменены `CHANGELOG.md`, `lib/src/*`, `test/*`, `example/*`; удалены `docs/КАРТА.md` и `mode_comparator`; добавлен `run_analyzer.dart`.
- Инструменты: Flutter 3.41.4 / Dart 3.11.1, Windows.
- Устройства: Pixel 8 Pro серийник `3A191FDJG0021L` — СЕЙЧАС ОТКЛЮЧЁН; к ПК подключён Xiaomi Mi A2 Lite `2b4a6e3e0205` — для прогона не использовать без спроса.
- Фона ничего нет: оба `flutter run` завершились (последний — «Lost connection to device»).

### Теневой измеритель (сделано на Этапе 0)

- `example/lib/opencv_features.dart` — `OpenCvFeatureExtractor`, `measure` → `OpenCvFrameMeasure`; паддинг строк YUV в `_toGray` чинится перекладкой строк в плотный буфер (в sim_app этой правки нет).
- `example/lib/opencv_shadow.dart` — `OpenCvShadowInstrument`; подключён как `session.shadowProbe`, вызывается в `detection_session.dart` последней (строки ~1168–1187), после отправки событий; try/catch и самозакрытие при первой ошибке.
- Пункт меню «OpenCV: второй измеритель» — `example/lib/home_page.dart`; отчёт — `lamp_opencv_compare.txt` в каталоге данных приложения, путь в logcat: «OPENCV отчёт: <path>».
- `example/pubspec.yaml`: `opencv_dart: 2.2.2`, `ffi: ^2.2.0`; `flutter pub get` — чисто, `flutter analyze --no-pub` — No issues found.
- APK собран: `example\build\app\outputs\flutter-apk\app-debug.apk`, 196.3 МБ, **не установлен**; внутри `libdartcv.so` arm64-v8a 10.5 МБ, armeabi-v7a 7.3 МБ, x86_64 14.9 МБ.
- Сборка один раз падала на залоченном кэше Gradle («Unable to delete ...\flutter_tools\gradle\build\classes\kotlin\main») — вылечено: убиты демоны Gradle (PID 23424, 9104, 2072), каталог `build` удалён.
- Размер OpenCV для релиза: ~10 МБ несжатых на одну arm64 (примерно 6–8 МБ в APK) — измерено по собранному APK.

### Точка входа рубильника

- `lib/src/session/detection_session.dart`: поле `final FeatureExtractor _extractor` (строка 215), создаётся в конструкторе (строка 173, `_extractor = FeatureExtractor(config)`). Используется всего в 3 местах: `loadSettings` (строка 499) и `applyConfig` (строка 891) — `_extractor.config = ...`; `_processFrame` (строка 1013) — `_extractor.extract(frame, _roi, source.mapping)`. Геттер `session.extractor` (строка 465) используется демо для отладочного дампа toRgb.
- Кадровая обработка `_onFrame` обёрнута в try/catch: ошибка печатается «Обработка кадра: $e», приложение не падает.
- Калибровка: `resetCalibration()` (строка 709) — стирает базу и собранные шаги, СЧЁТЧИКИ НЕ трогает; `newSession()` (строка 908) — новый sessionId, счётчики в ноль; `setRecordingCsv(false/true)` — останавливает/запускает CSV-файл (имя `lamp_features_<timestamp>_<sessionId>.csv`), формат CSV не меняется.

### Измерение и решение

- `lib/src/detection/feature_extractor.dart`: `FeatureExtractor.extract(frame, roi, mapping)` → `LampFrame(timestamp, white, red, whiteRing, redRing, exposureTimeNs, sensorSensitivity)`. Условие колец (строка 137): `withRing = config.ringScale > 1` — у OpenCV-измерителя условие ТО ЖЕ, расхождений нет.
- `FrameFeatures` (`lib/src/models/frame_features.dart`): meanY, sampleCount, whiteFrac, redFrac, p90Luma, lumaStdDev, clippedRatio.
- Решение принимается ТОЛЬКО по яркости: 8-мерный `LampVector` (mean + p90 четырёх областей: 2 колпака + 2 кольца), `lib/src/detection/response_model.dart`. Цветовая ветка решения УДАЛЕНА 20.11.2026 (CHANGELOG: `LampConfig.spatialVectors` удалён, `ModeComparator` удалён). whiteFrac/redFrac влияют только на CSV-диагностику. `live_reference.dart`: `_lit(f) = f.p90Luma / 255` — тоже только яркость.
- Штатный экстрактор на Android считает цвет из YUV по формуле BT.601 (класс `_YuvSource`, `yuvFullRange` по умолчанию true → берётся сырой Y). OpenCV-измеритель для YUV возвращает whiteFrac/redFrac = `null` (цветность не меряет).
- Правило null-кольца одинаковое у обоих измерителей: `core.sampleCount == 0 || ring.sampleCount * 4 < core.sampleCount` → `null`.

### CSV и тесты

- CSV: `FeatureCsvRow`, формат v3, ровно 41 колонка (`currentColumnCount = 41`), `lib/src/diagnostics/feature_csv_recorder.dart`. Колонка-маркер датчика НЕ планируется (сломала бы читаемость старых файлов); вместо этого при переключении перезаписывается CSV — новый файл = новый датчик.
- Тесты, которые могут отреагировать на правку пакета: `test/support/session_fakes.dart:209` (конструирует `DetectionSession`), `test/luma_features_test.dart` и `test/live_reference_test.dart` (используют `FeatureExtractor` напрямую).

### Объём правки (оценён)

- `detection_session.dart`: снять `final` с `_extractor`, сохранить прежний экстрактор в отдельное поле, добавить сеттер `sensorExtractor` (назначение → присвоить `config` и `_notify(force: true)`; `null` → возврат на штатный Dart-измеритель). Конструктор не меняется — обратная совместимость сохраняется.
- Новый файл `example/lib/opencv_sensor.dart`: `OpenCvSensorExtractor extends FeatureExtractor`, переопределяет `extract()`, внутри использует `OpenCvFeatureExtractor.measure()`; при null/исключении — fallback на `super.extract()` (Dart) для этого кадра + первая ошибка в лог; обязателен `dispose()` для Mat прошлого кадра.

## Реестр рисков и поломок

1. **Смешанная калибровка.** Пороги подобраны под Dart-числа. → OpenCV-измеритель проиграет не по своей вине (пороги чужие). → `resetCalibration()` при каждом переключении, обязательно (заложено в последовательность T4.3).
2. **Смешение CSV в одном файле.** Ряды Dart и OpenCV в одном файле. → Сравнение невозможно. → Перезапуск записи при переключении (новый файл `lamp_features_<timestamp>_<sessionId>.csv`), формат 41 колонка не менять.
3. **Нативный краш (SIGSEGV) в FFI.** Не ловится try/catch. → Падение приложения посреди прогона. → Откат слоями 1–4; буферы в `_toGray` уже проверяются на размер.
4. **Замедление на кадр.** OpenCV на кадр может замедлить анализ. → Пропуски вспышек. → Мерить ms/кадр (диагностика beginAnalysis/endAnalysis уже пишет), при росте — рубильник назад на Dart.
5. **Цветовые доли YUV у OpenCV отсутствуют.** В CSV нули вместо цвета. → См. открытый вопрос Q1; на решение не влияет (решение только по яркости).
6. **Дамп `session.extractor.toRgb` (LAMPDUMP).** Унаследуется от `FeatureExtractor` как Dart-путь. → Ничего не ломается: дамп остаётся рабочим. → Приемлемо (отладка).
7. **Присваивание `_extractor.config` в `loadSettings`/`applyConfig`.** → Подкласс унаследует присваивание — работает без правок.
8. **`test/support/session_fakes.dart:209` конструирует `DetectionSession`.** → Тест может отреагировать на правку пакета. → Конструктор не менять, правка только поля и сеттера.

## Откат

1. **На телефоне** — пунктом меню вернуть датчик Dart, без пересборки.
2. **На кадре** — при null/исключении измерителя кадр считается прежним Dart-путём (`super.extract()`).
3. **git** — `git checkout main` — возврат на исходную ветку.
4. **Полный** — `git checkout main`; все изменения разработки остаются на ветке `opencv_sensor`, ничего не теряется.

## Открытые вопросы

- **Q1. Чем заполнять whiteFrac/redFrac в OpenCV-датчике на YUV-кадре?** Нолём («не меряли», но в CSV будет ложный ноль) или копией формулы BT.601 (~40 строк, честная диагностика). **Рекомендация: копия формулы BT.601** — цвет на решение не влияет (решение только по яркости).
- **Q2. Делать ли snapshot-коммит WIP на main перед созданием ветки?** Нужно разрешение пользователя; альтернатива — ветка без коммита, тогда изменения просто переносятся в рабочем дереве.

## Команды

Windows / PowerShell:

```powershell
# Проверка устройства
adb devices

# Ветка (rollback: git checkout main); вторая команда — в каталоге lamp_detection
git -C C:\WORK\FLUTTER\WORK_PROJECTS\redandwhite\lamp_detection status --short
git checkout -b opencv_sensor

# Анализ
cd C:\WORK\FLUTTER\WORK_PROJECTS\redandwhite\lamp_detection\example ; flutter analyze --no-pub

# Тесты пакета
cd C:\WORK\FLUTTER\WORK_PROJECTS\redandwhite\lamp_detection ; flutter test

# Запуск демо
cd C:\WORK\FLUTTER\WORK_PROJECTS\redandwhite\lamp_detection\example ; flutter run -d 3A191FDJG0021L

# Установка уже собранного APK
adb install -r -d C:\WORK\FLUTTER\WORK_PROJECTS\redandwhite\lamp_detection\example\build\app\outputs\flutter-apk\app-debug.apk

# Логи
adb logcat | findstr LAMPDBG
adb logcat | findstr OPENCV
```

## Хроника 20.11.2026

- Ветка `opencv_sensor` создана **без snapshot-коммита** (Q2 закрыт пользовательским «продолжай»): 31 файл WIP перенесён, `main` не тронут.
- Пакет: `_extractor` перестал быть final, добавлены `_dartExtractor` и сеттер `sensorExtractor`; 63/63 теста зелёные.
- Demo: `opencv_sensor.dart`, пункт меню, сброс калибровки и перезапуск CSV при переключении, dispose нативного Mat; `flutter analyze --no-pub` чисто.
- APK собран и установлен на Pixel `3A191FDJG0021L`. Приложение запущено (`adb shell monkey ...`), кадры идут.
- **Найдена и исправлена поломка:** при первом переключении в логе появилось `OPENCVSENSOR кадр не измерен (yuv420) — считано по-старому`. Причина — проверка длины Y-плоскости требовала `stride * height`, а Camera2 отдаёт `(height-1) * stride + width` (последняя строка без паддинга), поэтому каждый кадр отклонялся и работал fallback. Исправлено в `_toGray` (`opencv_features.dart`), там же исправлена аналогичная проверка BGRA и добавлено поле `lastFailure` с причиной отказа в лог. Требуется пересборка и повторное переключение.
- Маркер `SENSOR OpenCV` в logcat подтверждён: меню и сеттер работают, краша нет.
- После второй пересборки APK установлен, но при повторном запуске USB-соединение с Pixel оборвалось (`adb devices` пусто) — **нужно физически переподключить кабель/порт**, затем повторить переключение и проверить отсутствие `OPENCVSENSOR кадр не измерен`. Это обрыв USB, не краш приложения.
- Final: интерфейс упрощён до двух пунктов «1 Считать по Dart» / «2 Только OpenCV», тень убрана из UI, OpenCV строго без fallback. APK пересобран (`flutter build apk --debug`, 33.6 с) и готов к установке; `adb devices` всё ещё пусто — ждём физического переподключения Pixel.

## Продолжение без автора

Строгий порядок (актуально после исправления `_toGray`):

1. Пересобрать APK: `cd ...\lamp_detection\example ; flutter build apk --debug`, затем `adb install -r -d ...app-debug.apk`.
2. Запустить демо (уже установлено, достаточно открыть приложение) и в меню выбрать «Датчик: OpenCV». В логе должно быть `SENSOR OpenCV` и **не должно** быть `OPENCVSENSOR кадр не измерен`. При повторном отказе причина теперь прямо в логе (`lastFailure`).
3. T1.2–T1.4: при желании сначала нуль-рисковая теневая сверка (меню «OpenCV: второй измеритель» → отчёт `lamp_opencv_compare.txt`), затем основные прогоны.
4. T5.1: Dart — перекалибровка 1 ФОН → 2 БЕЛАЯ → 3 КРАСНАЯ, сцена off → white → off → red → off, записать hits и ms/кадр.
5. T5.2: меню «Датчик: OpenCV» → **сброс калибровки уже автоматический**, снова 1 ФОН → 2 БЕЛАЯ → 3 КРАСНАЯ, та же сцена; маркер `SENSOR OpenCV` и новый CSV-файл подтверждают разделение.
6. T5.3: сравнить попадания / ложные / пропуски, `Y w/r`, `p90 w/r`, ms/кадр; T5.4 — решение и запись в `CHANGELOG.md`.
7. Возврат в любой момент: меню «Датчик: Dart» (без пересборки) или `git checkout main` (изменения остаются на `opencv_sensor`).
8. Постоянно обновлять таблицу статусов и эту хронику: дата, что сделано, что осталось.
