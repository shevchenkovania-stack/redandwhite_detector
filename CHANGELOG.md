# Changelog

## 0.0.1

Первый MVP-релиз. Пакет покрывает полный контур «кадр → событие → SQLite → очередь
доставки» для двух сигнальных ламп (белой и красной).

**Детекция**

- `FeatureExtractor` — обход ROI с подвыборкой каждый `subsampleStep`-й пиксель;
  YUV420 (Android, BT.601, полный/студийный диапазон) и BGRA8888 (iOS); признаки
  `meanY`, `brightFrac`, `sat`, `redDom`, `coreEdgeDiff`.
- `LampDetector` — формулы `whiteScore = brightFrac` (ноль при высокой насыщенности)
  и `redScore = ΔmeanY / redDeltaDivisor + coreEdgeBonus`; гистерезис ON/OFF,
  подтверждение `onConfirmFrames` / `offConfirmFrames`, разрешение неоднозначных
  кадров по `score / порог`.
- `HitStateMachine` — переходы `IDLE / WHITE_ON / RED_ON`; одно событие на переход;
  `HitEvent.detectedAt` = время кадра-кандидата, а не время сохранения.

**Хранилище и доставка**

- `SqliteEventRepository`: таблица `hit_events` с `event_id PRIMARY KEY`
  (`ConflictAlgorithm.ignore`), индексами `(session_id, sequence_number)` и
  `(delivery_status)`, статусами `pending / sent / failed` и счётчиком попыток.
- `HitEventSender` — один метод `send`; `MockHitEventSender` с флагами `offline`
  и `latency` для проверки очереди. Реальный HTTP/WebSocket подключается заменой
  одного класса.
- `DetectionSession.deliverPending()` — последовательная отправка, встает на
  первом неуспехе, оставшееся уходит при следующем запуске.

**Оркестрация**

- `DetectionSession` (`ChangeNotifier`) склеивает источник, детектор, автомат,
  хранилище, отправитель, CSV-рекордер и диагностику. Потоки `hits` и `errors`,
  `start` / `stop` без перезапуска приложения, `calibrate`, `replayCsv`,
  `newSession`, `resetCounters`, `applyConfig` (смена порогов на лету).
- `SettingsStore` (`shared_preferences`) хранит ROI, baseline, `LampConfig` и
  `sessionId` в четырёх JSON-строках.

**Диагностика**

- `DiagnosticsCollector` — FPS камеры и анализа, среднее/макс. время анализа,
  `droppedFrames`, `ambiguousFrames`, задержка «обнаружение → SQLite», экспозиция
  и ISO сенсора, флаг `needsIsolate`.
- `FeatureCsvRecorder` + `FeatureCsv.decode` + `DetectionSession.replayCsv` —
  запись признаков на устройстве и офлайн-подбор порогов на тех же детекторе и
  автомате.

**Источник кадров**

- `CameraFrameSource` на плагине `camera` 0.12: `ResolutionPreset.medium`, авто-
  расчёт `FrameMapping` из `sensorOrientation`, попытка зафиксировать AE/AWB через
  `lockSettle`, ручная коррекция `setFrameMapping(quarterTurns, mirror)`.

**Демо**

- `example/` — превью, перетаскиваемые `RoiEditor`, `ScoreChart`, журнал событий со
  статусами доставки, панель `DiagnosticsSnapshot`, переключатель сети для
  mock-доставки, запись CSV, кнопки новой сессии и поворота ROI.

**Известные ограничения в 0.0.1**

- `camera` 0.12 не отдаёт метку кадра — `LampFrame.timestamp` = время прихода в
  image stream, UTC-синхронизации с сервером нет.
- Перенос анализа в `Isolate` не реализован; `DiagnosticsSnapshot.needsIsolate`
  только подсказывает, что пора.
- `redScore` — абсолютный прирост `meanY`, поэтому сильное панорамирование рукой
  способно ложно поднять score; пороги подобраны под закреплённый телефон.
