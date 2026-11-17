import 'package:flutter/material.dart';
import 'package:lamp_detection/lamp_detection.dart';

/// Журнал событий с временем в формате ЧЧ:ММ:СС.мс и статусом доставки.
class EventLog extends StatelessWidget {
  const EventLog({super.key, required this.events, required this.statuses});

  final List<HitEvent> events;

  /// eventId -> текст статуса из SQLite (pending / sent / failed xN).
  final Map<String, String> statuses;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) {
      return const Center(child: Text('Событий пока нет', style: TextStyle(color: Colors.grey)));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(8),
      itemCount: events.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (BuildContext context, int index) {
        final HitEvent event = events[index];
        return ListTile(
          dense: true,
          leading: Text(
            '#${event.sequenceNumber}',
            style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold),
          ),
          title: Text(
            '${event.color == HitColor.white ? 'WHITE' : 'RED'}  ${formatClock(event.detectedAt)}',
            style: TextStyle(
              color: event.color == HitColor.white ? Colors.white : Colors.redAccent,
              fontWeight: FontWeight.bold,
            ),
          ),
          trailing: Text(
            statuses[event.eventId] ?? 'pending',
            style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
          ),
        );
      },
    );
  }

  /// ЧЧ:ММ:СС.мс
  static String formatClock(DateTime time) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}'
        '.${time.millisecond.toString().padLeft(3, '0')}';
  }
}
