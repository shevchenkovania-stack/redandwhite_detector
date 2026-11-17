import '../models/hit_event.dart';
import 'hit_event_sender.dart';

/// Заглушка доставки: «сеть есть» / «сети нет». Реальный транспорт в MVP не
/// пишется — интерфейс остаётся тем же, реализация меняется на HTTP/WebSocket.
class MockHitEventSender implements HitEventSender {
  MockHitEventSender({this.offline = false, this.latency = Duration.zero});

  /// true = имитация отсутствия сети: все попытки падают.
  bool offline;

  /// Имитация задержки сети.
  Duration latency;

  /// События, успешно «отправленные» — для проверки, что ничего не потерялось.
  final List<HitEvent> delivered = <HitEvent>[];

  int get attempts => delivered.length + _failures;

  int _failures = 0;

  @override
  Future<DeliveryResult> send(HitEvent event) async {
    if (latency > Duration.zero) {
      await Future<void>.delayed(latency);
    }
    if (offline) {
      _failures++;
      return const DeliveryResult.failure('нет сети (mock)');
    }
    delivered.add(event);
    return const DeliveryResult.success();
  }

  void reset() {
    delivered.clear();
    _failures = 0;
  }
}
