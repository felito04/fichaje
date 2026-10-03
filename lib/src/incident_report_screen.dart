import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'incident_report.dart';
import 'madrid_time.dart';
import 'medusa_api.dart';
import 'models.dart';
import 'nfc_card_animation.dart';
import 'services.dart';

enum _ReportPhase {
  identifying,
  recognized,
  form,
  summary,
  sending,
  success,
  error,
}

class IncidentReportScreen extends StatefulWidget {
  const IncidentReportScreen({super.key, required this.services});

  final AppServices services;

  @override
  State<IncidentReportScreen> createState() => _IncidentReportScreenState();
}

class _IncidentReportScreenState extends State<IncidentReportScreen> {
  final _comment = TextEditingController();
  _ReportPhase _phase = _ReportPhase.identifying;
  Timer? _idleTimer;
  Timer? _closeTimer;
  MedusaSession? _session;
  TodayState? _today;
  IncidentReason? _reason;
  bool _yesterday = false;
  bool _includeTime = true;
  String? _relatedEntryId;
  late TimeOfDay _correctTime;
  String _error = '';

  @override
  void initState() {
    super.initState();
    final now = madridNow();
    _correctTime = TimeOfDay(hour: now.hour, minute: now.minute);
    _resetIdleTimer();
    WidgetsBinding.instance.addPostFrameCallback((_) => _identify());
  }

  void _resetIdleTimer() {
    if (_phase == _ReportPhase.sending || _phase == _ReportPhase.success) {
      return;
    }
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(seconds: 60), _cancel);
  }

  void _cancel() {
    _session = null;
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _identify() async {
    try {
      final card = await widget.services.reader.cards().first.timeout(
        const Duration(seconds: 30),
        onTimeout: () =>
            throw const AppException('No se detectó ninguna tarjeta.'),
      );
      _resetIdleTimer();
      HapticFeedback.selectionClick();
      final result = await widget.services.registry.read(card);
      final credentials = await widget.services.codec.decode(
        result.payload,
        card.uid,
      );
      final session = await widget.services.api.login(
        credentials.email,
        credentials.password,
      );
      final today = await widget.services.api.today(session);
      final email = today.userEmail;
      if (today.userId == null || today.userId != credentials.userId) {
        throw const AppException(
          'La tarjeta no corresponde con el usuario autenticado.',
          kind: AppErrorKind.invalidCard,
        );
      }
      if (email == null ||
          !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
        throw const AppException(
          'El sistema no devolvió un email válido para este usuario.',
        );
      }
      if (!mounted) return;
      setState(() {
        _session = session;
        _today = today;
        _phase = _ReportPhase.recognized;
      });
      HapticFeedback.mediumImpact();
      _closeTimer?.cancel();
      _closeTimer = Timer(const Duration(milliseconds: 1200), () {
        if (mounted && _phase == _ReportPhase.recognized) {
          setState(() => _phase = _ReportPhase.form);
        }
      });
    } catch (error) {
      _fail(_friendly(error), closeAutomatically: true);
    }
  }

  DateTime get _affectedDate {
    final now = madridNow();
    final today = DateTime(now.year, now.month, now.day);
    return _yesterday ? today.subtract(const Duration(days: 1)) : today;
  }

  bool get _hasCorrectTime =>
      _reason != null && (_reason!.requiresCorrectTime || _includeTime);

  TimeEntry? get _relatedEntry {
    if (_yesterday || _relatedEntryId == null) return null;
    for (final entry in _today?.entries ?? const <TimeEntry>[]) {
      if (entry.id == _relatedEntryId) return entry;
    }
    return null;
  }

  IncidentDraft _draft({DateTime? sentAt}) => IncidentDraft(
    reason: _reason!,
    affectedDate: _affectedDate,
    correctHour: _hasCorrectTime ? _correctTime.hour : null,
    correctMinute: _hasCorrectTime ? _correctTime.minute : null,
    relatedEntry: _relatedEntry,
    comment: _comment.text,
    today: _today!,
    tabletId: widget.services.config.tabletId,
    baseUrl: widget.services.config.baseUrl,
    sentAt: sentAt ?? madridNow(),
  );

  void _review() {
    _resetIdleTimer();
    if (_reason == null) {
      _snack('Selecciona el motivo de la incidencia.');
      return;
    }
    if (_reason == IncidentReason.other && _comment.text.trim().isEmpty) {
      _snack('Escribe un comentario para explicar el problema.');
      return;
    }
    if (_hasCorrectTime) {
      final selected = madridDateTime(
        _affectedDate,
        hour: _correctTime.hour,
        minute: _correctTime.minute,
      );
      if (selected.isAfter(madridNow())) {
        _snack('La fecha y la hora indicadas no pueden ser futuras.');
        return;
      }
    }
    setState(() => _phase = _ReportPhase.summary);
  }

  Future<void> _send() async {
    if (_phase != _ReportPhase.summary || _session == null) return;
    _idleTimer?.cancel();
    setState(() => _phase = _ReportPhase.sending);
    final draft = _draft(sentAt: madridNow());
    try {
      await widget.services.api.submitTimeEntryIncident(
        _session!,
        title: draft.title,
        description: draft.description,
        userEmail: _today!.userEmail!,
        userName: _today!.userName,
        sourceUrl: draft.sourceUrl,
      );
      _session = null;
      if (!mounted) return;
      setState(() => _phase = _ReportPhase.success);
      HapticFeedback.heavyImpact();
      _closeTimer = Timer(const Duration(seconds: 4), _cancel);
    } catch (error) {
      _session = null;
      _fail(_friendly(error));
    }
  }

  void _fail(String message, {bool closeAutomatically = false}) {
    _session = null;
    if (!mounted) return;
    setState(() {
      _error = message;
      _phase = _ReportPhase.error;
    });
    if (closeAutomatically) {
      _closeTimer?.cancel();
      _closeTimer = Timer(const Duration(seconds: 6), _cancel);
    } else {
      _resetIdleTimer();
    }
  }

  Future<void> _chooseTime() async {
    _resetIdleTimer();
    var hour = _correctTime.hour;
    var minute = _correctTime.minute;
    final hourController = FixedExtentScrollController(initialItem: hour);
    final minuteController = FixedExtentScrollController(initialItem: minute);
    final selected = await showDialog<TimeOfDay>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hora correcta · Madrid'),
        content: SizedBox(
          width: 360,
          height: 220,
          child: Row(
            children: [
              Expanded(
                child: CupertinoPicker.builder(
                  scrollController: hourController,
                  itemExtent: 48,
                  childCount: 24,
                  onSelectedItemChanged: (value) => hour = value,
                  itemBuilder: (_, value) =>
                      Center(child: Text(value.toString().padLeft(2, '0'))),
                ),
              ),
              const Text(':', style: TextStyle(fontSize: 30)),
              Expanded(
                child: CupertinoPicker.builder(
                  scrollController: minuteController,
                  itemExtent: 48,
                  childCount: 60,
                  onSelectedItemChanged: (value) => minute = value,
                  itemBuilder: (_, value) =>
                      Center(child: Text(value.toString().padLeft(2, '0'))),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, TimeOfDay(hour: hour, minute: minute)),
            child: const Text('Aceptar'),
          ),
        ],
      ),
    );
    hourController.dispose();
    minuteController.dispose();
    if (selected != null && mounted) {
      setState(() => _correctTime = selected);
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) => _resetIdleTimer(),
    child: PopScope(
      onPopInvokedWithResult: (_, _) => _session = null,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: const Text('Incidencia de fichaje'),
          actions: [
            TextButton.icon(
              onPressed: _cancel,
              icon: const Icon(Icons.close),
              label: const Text('Cancelar'),
            ),
            const SizedBox(width: 12),
          ],
        ),
        body: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: switch (_phase) {
            _ReportPhase.identifying => _identifying(),
            _ReportPhase.recognized => _recognized(),
            _ReportPhase.form => _form(),
            _ReportPhase.summary => _summary(),
            _ReportPhase.sending => _sending(),
            _ReportPhase.success => _success(),
            _ReportPhase.error => _errorView(),
          },
        ),
      ),
    ),
  );

  Widget _identifying() => _cardStatus(
    key: const ValueKey('identifying'),
    mode: NfcCardAnimationMode.scanning,
    title: 'Acerca tu tarjeta para identificarte',
    subtitle: 'No se realizará ningún fichaje.',
  );

  Widget _recognized() => _cardStatus(
    key: const ValueKey('recognized'),
    mode: NfcCardAnimationMode.recognized,
    title: 'Tarjeta reconocida',
    subtitle: _today?.displayName ?? '',
  );

  Widget _form() {
    final today = _today!;
    final now = madridNow();
    final madridToday = DateTime(now.year, now.month, now.day);
    return LayoutBuilder(
      key: const ValueKey('form'),
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Hola, ${today.displayName}',
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Este reporte no modifica tus fichajes. Administración lo revisará.',
                  style: TextStyle(fontSize: 17),
                ),
                const SizedBox(height: 20),
                DropdownButtonFormField<IncidentReason>(
                  initialValue: _reason,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: '¿Qué ocurrió?',
                    prefixIcon: Icon(Icons.assignment_late_rounded),
                  ),
                  items: [
                    for (final reason in IncidentReason.values)
                      DropdownMenuItem(
                        value: reason,
                        child: Text(reason.label),
                      ),
                  ],
                  onChanged: (value) {
                    _resetIdleTimer();
                    setState(() {
                      _reason = value;
                      if (value?.requiresCorrectTime == true) {
                        _includeTime = true;
                      }
                    });
                  },
                ),
                const SizedBox(height: 18),
                Text(
                  'Fecha afectada',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 10),
                SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(
                      value: false,
                      label: Text(
                        'Hoy · ${DateFormat('dd/MM').format(madridToday)}',
                      ),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text(
                        'Ayer · ${DateFormat('dd/MM').format(madridToday.subtract(const Duration(days: 1)))}',
                      ),
                    ),
                  ],
                  selected: {_yesterday},
                  onSelectionChanged: (value) {
                    _resetIdleTimer();
                    setState(() {
                      _yesterday = value.first;
                      if (_yesterday) _relatedEntryId = null;
                    });
                  },
                ),
                const SizedBox(height: 16),
                _relatedEntrySelector(today),
                const SizedBox(height: 16),
                if (_reason == IncidentReason.other)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _includeTime,
                    onChanged: (value) => setState(() => _includeTime = value),
                    title: const Text('Indicar una hora correcta'),
                    subtitle: const Text('Para “Otro problema” es opcional.'),
                  ),
                if (_hasCorrectTime)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.schedule),
                    title: const Text('Hora correcta'),
                    subtitle: const Text(
                      'Hora de Madrid · formato de 24 horas',
                    ),
                    trailing: FilledButton.tonal(
                      onPressed: _chooseTime,
                      child: Text(
                        '${_correctTime.hour.toString().padLeft(2, '0')}:${_correctTime.minute.toString().padLeft(2, '0')}',
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                TextField(
                  controller: _comment,
                  minLines: 2,
                  maxLines: 4,
                  maxLength: 800,
                  onChanged: (_) => _resetIdleTimer(),
                  decoration: InputDecoration(
                    labelText: _reason == IncidentReason.other
                        ? 'Comentario obligatorio'
                        : 'Comentario opcional',
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _cancel,
                      child: const Text('Cancelar'),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      onPressed: _review,
                      icon: const Icon(Icons.arrow_forward),
                      label: const Text('Revisar reporte'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _relatedEntrySelector(TodayState today) {
    if (_yesterday) {
      return const ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.info_outline),
        title: Text('Fichaje relacionado (opcional)'),
        subtitle: Text(
          'Las marcas del día anterior no están disponibles desde el quiosco.',
        ),
      );
    }
    if (today.entries.isEmpty) {
      return const ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.event_busy_outlined),
        title: Text('Fichaje relacionado (opcional)'),
        subtitle: Text('Hoy todavía no hay fichajes para seleccionar.'),
      );
    }
    return DropdownButtonFormField<String>(
      key: ValueKey('related-entry-${_relatedEntryId ?? 'none'}'),
      initialValue: _relatedEntryId ?? '',
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Fichaje relacionado (opcional)',
        helperText: 'Elige la marca concreta si el problema corresponde a una.',
        prefixIcon: Icon(Icons.manage_history_rounded),
      ),
      items: [
        const DropdownMenuItem(value: '', child: Text('Ninguno en concreto')),
        for (final entry in today.entries)
          DropdownMenuItem(
            value: entry.id,
            child: Text(
              '${DateFormat('HH:mm').format(inMadrid(entry.time))} · ${entry.type.wireValue}',
            ),
          ),
      ],
      onChanged: (value) {
        _resetIdleTimer();
        setState(() => _relatedEntryId = value?.isEmpty == true ? null : value);
      },
    );
  }

  Widget _summary() {
    final draft = _draft();
    return SingleChildScrollView(
      key: const ValueKey('summary'),
      padding: const EdgeInsets.all(28),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Revisa antes de enviar',
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const SizedBox(height: 20),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _summaryLine('Empleado', _today!.displayName),
                      _summaryLine('Motivo', _reason!.label),
                      _summaryLine('Fecha', draft.affectedDateText),
                      _summaryLine(
                        'Hora correcta',
                        draft.correctTimeText ?? 'No indicada',
                      ),
                      _summaryLine(
                        'Fichaje relacionado',
                        draft.relatedEntryText ?? 'No seleccionado',
                      ),
                      _summaryLine(
                        'Comentario',
                        _comment.text.trim().isEmpty
                            ? '—'
                            : _comment.text.trim(),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Administración debe revisarlo en el sistema.',
                style: TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () {
                      _resetIdleTimer();
                      setState(() => _phase = _ReportPhase.form);
                    },
                    child: const Text('Volver'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: _send,
                    icon: const Icon(Icons.send),
                    label: const Text('Enviar'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _summaryLine(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 13),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 150,
          child: Text(label, style: const TextStyle(color: Colors.white60)),
        ),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 17))),
      ],
    ),
  );

  Widget _sending() => _centered(
    key: const ValueKey('sending'),
    icon: Icons.cloud_upload_outlined,
    title: 'Enviando reporte…',
    subtitle: 'No cierres la app ni pulses de nuevo.',
    progress: true,
  );

  Widget _success() => _centered(
    key: const ValueKey('success'),
    icon: Icons.check_circle,
    iconColor: Theme.of(context).colorScheme.primary,
    title: 'Reporte enviado',
    subtitle: 'Administración lo revisará.',
  );

  Widget _errorView() => _centered(
    key: const ValueKey('error'),
    icon: Icons.error_outline,
    iconColor: Colors.redAccent,
    title: 'No se envió el reporte',
    subtitle: _error,
    action: FilledButton.tonalIcon(
      onPressed: _cancel,
      icon: const Icon(Icons.close),
      label: const Text('Volver al quiosco'),
    ),
  );

  Widget _cardStatus({
    required Key key,
    required NfcCardAnimationMode mode,
    required String title,
    required String subtitle,
  }) => LayoutBuilder(
    key: key,
    builder: (context, constraints) {
      final compact = constraints.maxHeight < 500;
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedNfcCard(mode: mode, width: compact ? 190 : 280),
              SizedBox(height: compact ? 12 : 24),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                  fontSize: compact ? 28 : 38,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18),
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _centered({
    required Key key,
    required IconData icon,
    required String title,
    required String subtitle,
    Color? iconColor,
    bool progress = false,
    Widget? action,
  }) => Center(
    key: key,
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 104,
            color: iconColor ?? Theme.of(context).colorScheme.primary,
          ),
          if (progress) ...[
            const SizedBox(height: 20),
            const SizedBox(
              width: 44,
              height: 44,
              child: CircularProgressIndicator(),
            ),
          ],
          const SizedBox(height: 24),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineLarge,
          ),
          const SizedBox(height: 10),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18),
          ),
          if (action != null) ...[const SizedBox(height: 24), action],
        ],
      ),
    ),
  );

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  static String _friendly(Object error) => error is AppException
      ? error.message
      : 'No se pudo completar el reporte. Vuelve al quiosco e inténtalo de nuevo.';

  @override
  void dispose() {
    _session = null;
    _idleTimer?.cancel();
    _closeTimer?.cancel();
    _comment.dispose();
    super.dispose();
  }
}
