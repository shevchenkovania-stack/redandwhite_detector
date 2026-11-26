import 'package:uuid/uuid.dart';

import '../models/hit_event.dart';
import 'lamp_detector.dart';

/// Состояние автомата счёта попаданий (один автомат на обе лампы).
enum LampSessionState { idle, whiteOn, redOn }

/// Автомат: подтверждённое включение лампы = НОВОЕ событие.
///
/// Правила:
/// * IDLE -> WHITE_ON / RED_ON: одно новое событие;
/// * WHITE_ON -> WHITE_ON: событий нет (лампа горит, хоть 3 секунды);
/// * WHITE_ON -> IDLE: подтверждённое выключение, события нет;
/// * WHITE_ON -> RED_ON без паузы: второе событие (первое уже создано при
///   включении белой), порядок сохраняется;
/// * обе лампы выше ON-порога в одном кадре: событие всё равно ОДНО —
///   `LampDetector._oneBasket` оставляет победителя и гасит проигравшего ещё
///   до того, как автомат что-либо увидит (слово заказчика: двух одновременно
///   горящих ламп в производстве не бывает, «и туда, и сюда» — ошибка счёта).
///   Сам автомат этого правила не реализует, он получает его готовым.
class HitStateMachine {
  HitStateMachine({required this.sessionId, String Function()? idGenerator})
    : _nextId = idGenerator ?? _uuidV4;

  static const Uuid _uuid = Uuid();
  static String _uuidV4() => _uuid.v4();

  final String Function() _nextId;

  String sessionId;
  LampSessionState _state = LampSessionState.idle;
  int _sequence = 0;

  LampSessionState get state => _state;

  /// Номер следующего события (события нумеруются с 1 в рамках сессии).
  int get sequenceNumber => _sequence;

  /// Новая сессия: обнуляет нумерацию и состояние.
  void startSession(String newSessionId) {
    sessionId = newSessionId;
    _state = LampSessionState.idle;
    _whiteLit = false;
    _redLit = false;
    _sequence = 0;
  }

  /// Сброс состояния автомата без смены сессии (кнопка Reset в демо).
  void reset() {
    _state = LampSessionState.idle;
    _whiteLit = false;
    _redLit = false;
    _sequence = 0;
  }

  // Состояние каждой лампы ведётся отдельно: раньше общий `_state` терял
  /// «белая погасла», если между её включением и выключением успевала
  /// включиться красная.
  bool _whiteLit = false;
  bool _redLit = false;
  LampSessionState _lastOn = LampSessionState.idle;

  /// Скармливаем один кадр, получаем 0–2 события (по одному на лампу).
  List<HitEvent> onEvaluation(LampEvaluation evaluation) {
    final List<HitEvent> events = <HitEvent>[];

    if (evaluation.whiteOn) {
      events.add(
        _emit(
          lampId: HitEvent.whiteLampId,
          color: HitColor.white,
          detectedAt: evaluation.whiteOnCandidateAt ?? evaluation.timestamp,
        ),
      );
      _whiteLit = true;
      _lastOn = LampSessionState.whiteOn;
    }
    if (evaluation.redOn) {
      events.add(
        _emit(
          lampId: HitEvent.redLampId,
          color: HitColor.red,
          detectedAt: evaluation.redOnCandidateAt ?? evaluation.timestamp,
        ),
      );
      _redLit = true;
      _lastOn = LampSessionState.redOn;
    }
    if (evaluation.whiteOff) {
      _whiteLit = false;
    }
    if (evaluation.redOff) {
      _redLit = false;
    }
    _state = _derive();
    return events;
  }

  LampSessionState _derive() {
    if (_whiteLit && _redLit) {
      return _lastOn;
    }
    if (_whiteLit) {
      return LampSessionState.whiteOn;
    }
    if (_redLit) {
      return LampSessionState.redOn;
    }
    return LampSessionState.idle;
  }

  HitEvent _emit({required String lampId, required HitColor color, required DateTime detectedAt}) {
    _sequence++;
    return HitEvent(
      eventId: _nextId(),
      lampId: lampId,
      color: color,
      detectedAt: detectedAt,
      sequenceNumber: _sequence,
      sessionId: sessionId,
    );
  }
}
