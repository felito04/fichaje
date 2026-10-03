import 'package:intl/intl.dart';

import 'madrid_time.dart';
import 'models.dart';

enum IncidentReason {
  lateClockIn('ENTRADA_TARDE', 'Marqué la entrada tarde', true),
  forgotClockIn('OLVIDO_ENTRADA', 'Se me olvidó marcar la entrada', true),
  forgotClockOut('OLVIDO_SALIDA', 'Se me olvidó marcar la salida', true),
  earlyClockOut('SALIDA_ANTES', 'Marqué la salida antes de tiempo', true),
  forgotPauseStart(
    'OLVIDO_INICIO_PAUSA',
    'Se me olvidó marcar el inicio de pausa',
    true,
  ),
  forgotPauseEnd(
    'OLVIDO_FIN_PAUSA',
    'Se me olvidó marcar el fin de pausa',
    true,
  ),
  incorrectEntry(
    'FICHAJE_ERRONEO',
    'Hice un fichaje por error (sobra uno)',
    true,
  ),
  other('OTRO', 'Otro problema', false);

  const IncidentReason(this.code, this.label, this.requiresCorrectTime);

  final String code;
  final String label;
  final bool requiresCorrectTime;
}

class IncidentDraft {
  const IncidentDraft({
    required this.reason,
    required this.affectedDate,
    required this.correctHour,
    required this.correctMinute,
    required this.relatedEntry,
    required this.comment,
    required this.today,
    required this.tabletId,
    required this.baseUrl,
    required this.sentAt,
  });

  final IncidentReason reason;
  final DateTime affectedDate;
  final int? correctHour;
  final int? correctMinute;
  final TimeEntry? relatedEntry;
  final String comment;
  final TodayState today;
  final String tabletId;
  final String baseUrl;
  final DateTime sentAt;

  String get affectedDateText => DateFormat('dd/MM/yyyy').format(affectedDate);

  String? get correctTimeText => correctHour == null || correctMinute == null
      ? null
      : '${correctHour!.toString().padLeft(2, '0')}:${correctMinute!.toString().padLeft(2, '0')}';

  String? get relatedEntryText => relatedEntry == null
      ? null
      : '${DateFormat('HH:mm').format(inMadrid(relatedEntry!.time))} · ${relatedEntry!.type.wireValue}';

  String get title =>
      '[Fichaje] ${reason.label} – ${today.displayName} – $affectedDateText';

  String get sourceUrl =>
      '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/app/time-entry?origen=quiosco-nfc';

  String get description {
    final email = today.userEmail!;
    final time = correctTimeText;
    final markLines = _isSameMadridDay(affectedDate, sentAt)
        ? today.entries.isEmpty
              ? 'Ninguna'
              : today.entries
                    .map(
                      (entry) =>
                          '- ${DateFormat('HH:mm').format(inMadrid(entry.time))} ${entry.type.wireValue}',
                    )
                    .join('\n')
        : 'No disponible desde el quiosco (día anterior)';
    return '''Origen: Quiosco NFC ($tabletId)
Empleado: ${today.displayName} <$email> (user_id: ${today.userId})
Motivo: ${reason.label} [${reason.code}]
Fecha afectada: $affectedDateText
Hora correcta indicada: ${time == null ? '—' : '$time (hora de Madrid)'}
Fichaje relacionado: ${relatedEntry == null ? '—' : '${relatedEntryText!} (id: ${relatedEntry!.id})'}
Comentario: ${comment.trim().isEmpty ? '—' : comment.trim()}

Marcas registradas ese día (según el sistema):
$markLines

Enviado: ${DateFormat('dd/MM/yyyy HH:mm:ss').format(sentAt)} desde la tablet''';
  }

  static bool _isSameMadridDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}
