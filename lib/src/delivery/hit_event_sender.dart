import '../models/hit_event.dart';

/// Результат попытки доставки.
class DeliveryResult {
  const DeliveryResult.success() : success = true, error = null;

  const DeliveryResult.failure(this.error) : success = false;

  final bool success;
  final String? error;

  @override
  String toString() => success ? 'sent' : 'failed: $error';
}

/// Доставка события на сервер. Реальный HTTP/WebSocket в MVP не пишется.
abstract interface class HitEventSender {
  Future<DeliveryResult> send(HitEvent event);
}
