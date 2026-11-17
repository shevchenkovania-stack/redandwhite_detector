/// Цвет сигнальной лампы системы подсчёта попаданий.
enum HitColor { red, white }

/// Одно событие попадания: новое включение лампы.
///
/// [detectedAt] берётся из метки времени кадра, в котором лампа впервые стала
/// кандидатом ON, а не из момента сохранения или отправки.
class HitEvent {
  const HitEvent({
    required this.eventId,
    required this.lampId,
    required this.color,
    required this.detectedAt,
    required this.sequenceNumber,
    required this.sessionId,
  });

  /// Идентификатор лампы: `'white'` или `'red'`.
  static const String whiteLampId = 'white';
  static const String redLampId = 'red';

  /// uuid v4, PRIMARY KEY в SQLite — защита от дублей.
  final String eventId;

  /// `'white'` | `'red'`.
  final String lampId;

  final HitColor color;

  /// Время кадра, где лампа впервые стала кандидатом ON.
  final DateTime detectedAt;

  /// Нумерация с 1 в рамках сессии.
  final int sequenceNumber;

  final String sessionId;

  /// Строка для таблицы `hit_events`.
  Map<String, Object?> toMap() => <String, Object?>{
    'event_id': eventId,
    'session_id': sessionId,
    'lamp_id': lampId,
    'color': color.name,
    'detected_at_ms': detectedAt.millisecondsSinceEpoch,
    'sequence_number': sequenceNumber,
  };

  factory HitEvent.fromMap(Map<String, Object?> map) => HitEvent(
    eventId: map['event_id']! as String,
    lampId: map['lamp_id']! as String,
    color: HitColor.values.firstWhere(
      (HitColor c) => c.name == map['color'],
      orElse: () => throw StateError('Неизвестный color: ${map['color']}'),
    ),
    detectedAt: DateTime.fromMillisecondsSinceEpoch(map['detected_at_ms']! as int),
    sequenceNumber: map['sequence_number']! as int,
    sessionId: map['session_id']! as String,
  );

  @override
  bool operator ==(Object other) =>
      other is HitEvent &&
      other.eventId == eventId &&
      other.lampId == lampId &&
      other.color == color &&
      other.detectedAt == detectedAt &&
      other.sequenceNumber == sequenceNumber &&
      other.sessionId == sessionId;

  @override
  int get hashCode =>
      Object.hash(eventId, lampId, color, detectedAt, sequenceNumber, sessionId);

  @override
  String toString() =>
      'HitEvent(#$sequenceNumber $lampId at ${detectedAt.toIso8601String()}, session $sessionId)';
}
