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
/// * неоднозначный кадр разрешается детектором в одного победителя, поэтому
///   здесь за кадр максимум одно событие.
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
    _sequence = 0;
  }

  /// Сброс состояния автомата без смены сессии (кнопка Reset в демо).
  void reset() {
    _state = LampSessionState.idle;
    _sequence = 0;
  }

  /// Скармливаем один кадр, получаем 0 или 1 событие.
  List<HitEvent> onEvaluation(LampEvaluation evaluation) {
    final List<HitEvent> events = <HitEvent>[];

    if (evaluation.whiteOn && _state != LampSessionState.whiteOn) {
      events.add(
        _emit(
          lampId: HitEvent.whiteLampId,
          color: HitColor.white,
          detectedAt: evaluation.whiteOnCandidateAt ?? evaluation.timestamp,
        ),
      );
      _state = LampSessionState.whiteOn;
    }

    if (evaluation.redOn && _state != LampSessionState.redOn) {
      events.add(
        _emit(
          lampId: HitEvent.redLampId,
          color: HitColor.red,
          detectedAt: evaluation.redOnCandidateAt ?? evaluation.timestamp,
        ),
      );
      _state = LampSessionState.redOn;
    }

    if (_state == LampSessionState.whiteOn && evaluation.whiteOff) {
      _state = LampSessionState.idle;
    } else if (_state == LampSessionState.redOn && evaluation.redOff) {
      _state = LampSessionState.idle;
    }

    return events;
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
