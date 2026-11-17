import '../models/hit_event.dart';

/// Статус доставки события серверу.
enum DeliveryStatus { pending, sent, failed }

DeliveryStatus deliveryStatusFromName(String name) => DeliveryStatus.values.firstWhere(
  (DeliveryStatus s) => s.name == name,
  orElse: () => DeliveryStatus.pending,
);

/// Событие вместе с состоянием его доставки.
class StoredEvent {
  const StoredEvent({
    required this.event,
    required this.status,
    required this.attempts,
    this.lastAttemptAt,
  });

  final HitEvent event;
  final DeliveryStatus status;
  final int attempts;
  final DateTime? lastAttemptAt;

  bool get isDelivered => status == DeliveryStatus.sent;

  factory StoredEvent.fromMap(Map<String, Object?> map) => StoredEvent(
    event: HitEvent.fromMap(map),
    status: deliveryStatusFromName(map['delivery_status'] as String? ?? DeliveryStatus.pending.name),
    attempts: (map['attempts'] as int?) ?? 0,
    lastAttemptAt: map['last_attempt_at_ms'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(map['last_attempt_at_ms']! as int),
  );

  @override
  String toString() => '${event.lampId}#${event.sequenceNumber} ${status.name} (x$attempts)';
}

/// Хранилище событий. Событие сначала пишется сюда, и только потом уходит
/// в UI и в очередь доставки.
abstract interface class EventRepository {
  /// Сохраняет событие. Дубликат по [HitEvent.eventId] молча игнорируется —
  /// PRIMARY KEY защищает от повторной записи.
  Future<void> save(HitEvent event);

  /// Все события сессии по порядку номеров.
  Future<List<HitEvent>> history(String sessionId);

  /// Недоставленные (pending или failed) события всех сессий, по времени.
  Future<List<HitEvent>> pending();

  /// События сессии вместе со статусом доставки — для журнала в демо.
  Future<List<StoredEvent>> eventsWithStatus(String sessionId);

  Future<void> markSent(String eventId);

  /// Неудача: статус failed, attempts + 1, время последней попытки.
  Future<void> markFailed(String eventId);

  /// Удаляет события сессии (используется для «Reset» и тестов).
  Future<void> resetSession(String sessionId);

  Future<void> dispose();
}
