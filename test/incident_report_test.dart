import 'package:fichaje/src/incident_report.dart';
import 'package:fichaje/src/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;

void main() {
  tz.initializeTimeZones();

  test('builds the fixed Medusa title, URL and description', () {
    final today = TodayState.fromJson({
      'entries': [
        {
          'id': 'entry_1',
          'entry_type': 'ENTRADA',
          'clock_time': '2026-10-03T06:02:00.000Z',
        },
      ],
      'user': {
        'id': 'user_1',
        'email': 'ana@example.com',
        'display_name': 'Ana López',
      },
    }, 'fallback');
    final draft = IncidentDraft(
      reason: IncidentReason.forgotClockOut,
      affectedDate: DateTime(2026, 10, 3),
      correctHour: 17,
      correctMinute: 30,
      relatedEntry: today.entries.first,
      comment: '',
      today: today,
      tabletId: 'tablet-oficina-1',
      baseUrl: 'https://staging.example.com/',
      sentAt: DateTime(2026, 10, 3, 18, 1, 2),
    );

    expect(
      draft.title,
      '[Fichaje] Se me olvidó marcar la salida – Ana López – 03/10/2026',
    );
    expect(
      draft.sourceUrl,
      'https://staging.example.com/app/time-entry?origen=quiosco-nfc',
    );
    expect(
      draft.description,
      contains('Empleado: Ana López <ana@example.com>'),
    );
    expect(draft.description, contains('Hora correcta indicada: 17:30'));
    expect(draft.description, contains('- 08:02 ENTRADA'));
    expect(
      draft.description,
      contains('Fichaje relacionado: 08:02 · ENTRADA (id: entry_1)'),
    );
    expect(draft.description, isNot(contains('photos')));
  });

  test('does not claim to know yesterday entries', () {
    final today = TodayState.fromJson({
      'entries': const [],
      'user': {
        'id': 'user_1',
        'email': 'ana@example.com',
        'display_name': 'Ana',
      },
    }, 'fallback');
    final draft = IncidentDraft(
      reason: IncidentReason.other,
      affectedDate: DateTime(2026, 10, 2),
      correctHour: null,
      correctMinute: null,
      relatedEntry: null,
      comment: 'No aparece una marca',
      today: today,
      tabletId: 'tablet-1',
      baseUrl: 'https://example.com',
      sentAt: DateTime(2026, 10, 3, 8),
    );

    expect(
      draft.description,
      contains('No disponible desde el quiosco (día anterior)'),
    );
    expect(draft.description, contains('Hora correcta indicada: —'));
  });
}
