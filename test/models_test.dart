import 'package:fichaje/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TodayState', () {
    test('derives every kiosk state from the last entry', () {
      TodayState state(List<Map<String, dynamic>> entries) =>
          TodayState.fromJson({
            'entries': entries,
            'user': {'id': 'user_1', 'display_name': 'Ada Lovelace'},
          }, 'fallback');

      expect(state([]).status, WorkStatus.notClockedIn);
      expect(state([_entry('ENTRADA', 8)]).status, WorkStatus.working);
      expect(
        state([_entry('ENTRADA', 8), _entry('PAUSA_INICIO', 10)]).status,
        WorkStatus.paused,
      );
      expect(
        state([_entry('PAUSA_INICIO', 10), _entry('PAUSA_FIN', 11)]).status,
        WorkStatus.working,
      );
      expect(
        state([_entry('ENTRADA', 8), _entry('SALIDA', 17)]).status,
        WorkStatus.notClockedIn,
      );
    });

    test('calculates worked time from entries instead of backend summary', () {
      final state = TodayState.fromJson({
        'entries': [
          _entry('ENTRADA', 8),
          _entry('PAUSA_INICIO', 10),
          _entry('PAUSA_FIN', 11),
          _entry('SALIDA', 14),
        ],
        'summary': {'total_worked_minutes': 9999},
        'user': {'id': 'user_1', 'display_name': 'Ada'},
      }, 'fallback');
      expect(state.workedDuration, const Duration(hours: 5));
    });
  });
}

Map<String, dynamic> _entry(String type, int hour) => {
  'id': '$type-$hour',
  'entry_type': type,
  'clock_time': DateTime.utc(2026, 10, 3, hour).toIso8601String(),
};
