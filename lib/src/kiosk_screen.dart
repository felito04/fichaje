import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import 'admin_screen.dart';
import 'medusa_api.dart';
import 'madrid_time.dart';
import 'models.dart';
import 'services.dart';

enum _KioskPhase {
  waiting,
  reading,
  recognized,
  choosing,
  processing,
  success,
  error,
}

enum _NfcCardAnimationMode { scanning, recognized }

class KioskScreen extends StatefulWidget {
  const KioskScreen({super.key, required this.services});
  final AppServices services;

  @override
  State<KioskScreen> createState() => _KioskScreenState();
}

class _KioskScreenState extends State<KioskScreen> with WidgetsBindingObserver {
  _KioskPhase _phase = _KioskPhase.waiting;
  StreamSubscription<DetectedCard>? _cards;
  Timer? _clock;
  Timer? _countdownTimer;
  Timer? _readerWatchdog;
  Timer? _recognitionTimer;
  DateTime _now = madridNow();
  DateTime? _lastSuccessAt;
  String? _lastUid;
  int _countdown = 4;
  int _logoTaps = 0;
  DateTime? _firstLogoTap;
  String _message = '';
  TodayState? _today;
  MedusaSession? _session;
  DetectedCard? _card;
  PunchAction? _activeAction;
  DateTime? _completedAt;
  bool _cardRecognitionError = false;
  bool _readerReady = false;
  bool _readerRestarting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = madridNow());
    });
    _cards = widget.services.reader.cards().listen(
      _onCard,
      onError: (Object error) {
        if (mounted) setState(() => _readerReady = false);
        _showError(_friendly(error));
      },
    );
    _readerWatchdog = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_phase == _KioskPhase.waiting) _rearmReader();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _startReader());
  }

  Future<void> _startReader() async {
    try {
      await widget.services.reader.start();
      await KioskPlatform.start();
      if (mounted) setState(() => _readerReady = true);
    } catch (error) {
      if (mounted) setState(() => _readerReady = false);
      _showError(_friendly(error));
    }
  }

  Future<void> _rearmReader() async {
    if (_readerRestarting || !mounted || _phase != _KioskPhase.waiting) return;
    _readerRestarting = true;
    try {
      await widget.services.reader.restart();
      if (mounted) setState(() => _readerReady = true);
    } catch (_) {
      if (mounted) setState(() => _readerReady = false);
    } finally {
      _readerRestarting = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _rearmReader();
  }

  Future<void> _onCard(DetectedCard card) async {
    if (_phase != _KioskPhase.waiting) return;
    if (_lastUid == card.uidHex &&
        _lastSuccessAt != null &&
        DateTime.now().difference(_lastSuccessAt!) <
            const Duration(seconds: 10)) {
      return;
    }
    setState(() {
      _readerReady = true;
      _cardRecognitionError = false;
      _activeAction = null;
      _phase = _KioskPhase.reading;
      _message = 'Leyendo tarjeta…';
    });
    HapticFeedback.selectionClick();
    try {
      final result = await widget.services.registry.read(card);
      final credentials = await widget.services.codec.decode(
        result.payload,
        card.uid,
      );
      final api = widget.services.api;
      final session = await api.login(credentials.email, credentials.password);
      final today = await api.today(session);
      if (today.userId == null || today.userId != credentials.userId) {
        throw const AppException(
          'La tarjeta no corresponde con el usuario autenticado.',
          kind: AppErrorKind.invalidCard,
        );
      }
      if (!mounted) return;
      setState(() {
        _card = card;
        _session = session;
        _today = today;
        _phase = _KioskPhase.recognized;
        _message = 'Tarjeta reconocida';
        _countdown = 4;
      });
      HapticFeedback.mediumImpact();
      _recognitionTimer?.cancel();
      _recognitionTimer = Timer(const Duration(milliseconds: 1200), () {
        if (!mounted || _phase != _KioskPhase.recognized) return;
        setState(() => _phase = _KioskPhase.choosing);
        _startActionCountdown();
      });
    } catch (error) {
      _showError(
        error is AppException && error.kind == AppErrorKind.invalidCredentials
            ? 'Tu tarjeta está desactualizada (¿cambiaste la contraseña?). Avisa a administración.'
            : _friendly(error),
        cardRecognitionError:
            error is AppException && error.kind == AppErrorKind.invalidCard,
      );
    }
  }

  void _startActionCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _phase != _KioskPhase.choosing) {
        timer.cancel();
        return;
      }
      if (_countdown <= 1) {
        timer.cancel();
        _perform(_today!.suggestedAction);
      } else {
        setState(() => _countdown--);
      }
    });
  }

  Future<void> _perform(PunchAction action) async {
    if (_phase != _KioskPhase.choosing || _session == null || _today == null) {
      return;
    }
    _countdownTimer?.cancel();
    _recognitionTimer?.cancel();
    setState(() {
      _activeAction = action;
      _phase = _KioskPhase.processing;
      _message = _actionProgress(action);
    });
    try {
      final api = widget.services.api;
      DateTime time;
      if (_today!.status == WorkStatus.paused &&
          action == PunchAction.clockOut) {
        await api.perform(
          _session!,
          PunchAction.pauseEnd,
          idempotencyKey: const Uuid().v4(),
          config: widget.services.config,
        );
        time = await api.perform(
          _session!,
          PunchAction.clockOut,
          idempotencyKey: const Uuid().v4(),
          config: widget.services.config,
        );
      } else {
        time = await api.perform(
          _session!,
          action,
          idempotencyKey: const Uuid().v4(),
          config: widget.services.config,
        );
      }
      _lastUid = _card?.uidHex;
      _lastSuccessAt = DateTime.now();
      HapticFeedback.heavyImpact();
      if (!mounted) return;
      setState(() {
        _phase = _KioskPhase.success;
        _completedAt = inMadrid(time);
        _message =
            '${_actionPast(action)} registrada — ${DateFormat('HH:mm').format(_completedAt!)}';
      });
      Timer(const Duration(seconds: 3), _reset);
    } catch (error) {
      _showError(_friendly(error));
    } finally {
      _session = null;
    }
  }

  void _showError(String message, {bool cardRecognitionError = false}) {
    if (!mounted) return;
    _session = null;
    setState(() {
      _cardRecognitionError = cardRecognitionError;
      _phase = _KioskPhase.error;
      _message = message;
    });
    Timer(const Duration(seconds: 5), _reset);
  }

  void _reset() {
    if (!mounted) return;
    _countdownTimer?.cancel();
    setState(() {
      _phase = _KioskPhase.waiting;
      _message = '';
      _today = null;
      _session = null;
      _card = null;
      _activeAction = null;
      _completedAt = null;
      _cardRecognitionError = false;
      _countdown = 4;
    });
    Future<void>.delayed(const Duration(milliseconds: 250), _rearmReader);
  }

  Future<void> _logoTap() async {
    if (_phase != _KioskPhase.waiting) return;
    final now = DateTime.now();
    if (_firstLogoTap == null ||
        now.difference(_firstLogoTap!) > const Duration(seconds: 3)) {
      _firstLogoTap = now;
      _logoTaps = 0;
    }
    _logoTaps++;
    if (_logoTaps < 5) return;
    _logoTaps = 0;
    await _openAdmin();
  }

  Future<void> _openAdmin() async {
    _countdownTimer?.cancel();
    final configured = await widget.services.pinStore.isConfigured;
    if (!mounted) return;
    final pin = await _askPin(firstSetup: !configured);
    if (pin == null || !mounted) return;
    if (!configured) {
      try {
        await widget.services.pinStore.setPin(pin);
      } catch (error) {
        if (mounted) _snack(_friendly(error));
        return;
      }
    } else if (!await widget.services.pinStore.verify(pin)) {
      if (mounted) _snack('PIN incorrecto.');
      return;
    }
    await KioskPlatform.stop();
    await widget.services.reader.stop();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => AdminScreen(services: widget.services)),
    );
    _reset();
    await _startReader();
  }

  Future<String?> _askPin({required bool firstSetup}) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(
          firstSetup ? 'Crear PIN de administración' : 'Modo Administración',
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: 8,
          decoration: InputDecoration(
            labelText: firstSetup ? 'Nuevo PIN (4–8 cifras)' : 'PIN',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Continuar'),
          ),
        ],
      ),
    );
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: switch (_phase) {
          _KioskPhase.waiting => _waiting(),
          _KioskPhase.reading => _readingCard(),
          _KioskPhase.recognized => _recognizedCard(),
          _KioskPhase.processing => _progress(),
          _KioskPhase.choosing => _employee(),
          _KioskPhase.success => _result(success: true),
          _KioskPhase.error => _result(success: false),
        },
      ),
    );
  }

  Widget _brand() => GestureDetector(
    onTap: _logoTap,
    child: Image.asset(
      'assets/branding/myurban_logo.png',
      height: 27,
      fit: BoxFit.contain,
      alignment: Alignment.centerLeft,
      errorBuilder: (_, _, _) => const Text(
        'MYURBAN SCOOT',
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
      ),
    ),
  );

  Widget _waiting() => LayoutBuilder(
    key: const ValueKey('waiting'),
    builder: (context, constraints) {
      final compact = constraints.maxHeight < 500;
      return Stack(
        fit: StackFit.expand,
        children: [
          Opacity(
            opacity: 0.24,
            child: Image.asset(
              'assets/branding/myurban_background.png',
              fit: BoxFit.cover,
              alignment: Alignment.center,
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xee080a08), Color(0x99080a08)],
              ),
            ),
          ),
          _scrollableViewport(
            constraints: constraints,
            padding: EdgeInsets.all(compact ? 20 : 36),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: _brand(),
                      ),
                    ),
                    IconButton(
                      onPressed: _openAdmin,
                      tooltip: 'Configurar tarjetas',
                      icon: const Icon(Icons.admin_panel_settings_outlined),
                    ),
                  ],
                ),
                const Spacer(),
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: DateFormat('HH:mm').format(_now)),
                      TextSpan(
                        text: DateFormat(':ss').format(_now),
                        style: TextStyle(
                          fontSize: compact ? 27 : 38,
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0,
                        ),
                      ),
                    ],
                  ),
                  style: Theme.of(context).textTheme.displayLarge?.copyWith(
                    fontSize: compact ? 66 : 104,
                    color: Colors.white,
                  ),
                ),
                Text(
                  DateFormat("EEEE, d 'de' MMMM", 'es_ES').format(_now),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontSize: compact ? 19 : 25,
                    color: Colors.white70,
                  ),
                ),
                SizedBox(height: compact ? 14 : 32),
                Semantics(
                  image: true,
                  label: 'Tarjeta NFC de los trabajadores',
                  child: Container(
                    width: compact ? 150 : 230,
                    height: compact ? 90 : 145,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withAlpha(42),
                          blurRadius: 34,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: Image.asset(
                      'assets/branding/worker_nfc_card.png',
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.high,
                    ),
                  ),
                ),
                SizedBox(height: compact ? 8 : 16),
                Text(
                  'Acerca tu tarjeta',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                    fontSize: compact ? 28 : 38,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _readerReady
                      ? 'El lector está preparado'
                      : 'Reactivando el lector NFC…',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 17, color: Colors.white60),
                ),
                const Spacer(),
              ],
            ),
          ),
        ],
      );
    },
  );

  Widget _progress() => LayoutBuilder(
    key: ValueKey(_phase),
    builder: (context, constraints) {
      final compact = constraints.maxHeight < 430;
      return _scrollableViewport(
        constraints: constraints,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_activeAction != null)
              _PunchActionAnimation(
                action: _activeAction!,
                processing: true,
                size: compact ? 112 : 160,
              )
            else
              const SizedBox(
                width: 72,
                height: 72,
                child: CircularProgressIndicator(strokeWidth: 7),
              ),
            SizedBox(height: compact ? 16 : 28),
            Text(
              _message,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.headlineLarge?.copyWith(fontSize: compact ? 28 : 38),
            ),
          ],
        ),
      );
    },
  );

  Widget _readingCard() => LayoutBuilder(
    key: const ValueKey('reading-card'),
    builder: (context, constraints) {
      final compact = constraints.maxHeight < 430;
      return _scrollableViewport(
        constraints: constraints,
        padding: EdgeInsets.all(compact ? 18 : 30),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _AnimatedNfcCard(
              mode: _NfcCardAnimationMode.scanning,
              width: compact ? 180 : 280,
            ),
            SizedBox(height: compact ? 12 : 24),
            Text(
              'Reconociendo tarjeta…',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.headlineLarge?.copyWith(fontSize: compact ? 28 : 38),
            ),
            const SizedBox(height: 8),
            Text(
              'Descifrando y comprobando tus datos',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: compact ? 16 : 18,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _recognizedCard() => LayoutBuilder(
    key: const ValueKey('recognized-card'),
    builder: (context, constraints) {
      final compact = constraints.maxHeight < 430;
      return Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            colors: [Color(0xff263500), Color(0xff080a08)],
            radius: 1.1,
          ),
        ),
        child: _scrollableViewport(
          constraints: constraints,
          padding: EdgeInsets.all(compact ? 18 : 30),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _AnimatedNfcCard(
                mode: _NfcCardAnimationMode.recognized,
                width: compact ? 180 : 280,
              ),
              SizedBox(height: compact ? 10 : 22),
              Text(
                'Tarjeta reconocida',
                style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontSize: compact ? 28 : 40,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _today?.displayName ?? '',
                style: TextStyle(
                  fontSize: compact ? 18 : 22,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _employee() {
    final today = _today!;
    final last = today.last;
    final status = switch (today.status) {
      WorkStatus.notClockedIn => 'Sin fichar',
      WorkStatus.working =>
        'Trabajando${last == null ? '' : ' desde ${DateFormat('HH:mm').format(inMadrid(last.time))}'}',
      WorkStatus.paused =>
        'En pausa desde ${DateFormat('HH:mm').format(inMadrid(last!.time))}',
    };
    final worked = today.workedDuration;
    final alternatives = switch (today.status) {
      WorkStatus.notClockedIn => <PunchAction>[],
      WorkStatus.working => [PunchAction.pauseMeal, PunchAction.pauseBreak],
      WorkStatus.paused => [PunchAction.clockOut],
    };
    return LayoutBuilder(
      key: const ValueKey('employee'),
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 500;
        final narrow = constraints.maxWidth < 720;
        final info = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _brand(),
            SizedBox(height: compact ? 18 : 36),
            Text(
              'Hola, ${today.displayName}',
              style: Theme.of(
                context,
              ).textTheme.headlineLarge?.copyWith(fontSize: compact ? 28 : 38),
            ),
            SizedBox(height: compact ? 8 : 18),
            Text(status, style: TextStyle(fontSize: compact ? 21 : 26)),
            const SizedBox(height: 8),
            Text(
              'Tiempo trabajado hoy: ${worked.inHours} h ${(worked.inMinutes % 60).toString().padLeft(2, '0')} min',
              style: TextStyle(
                fontSize: 17,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            SizedBox(height: compact ? 10 : 24),
            TextButton.icon(
              onPressed: _reset,
              icon: const Icon(Icons.close),
              label: const Text('Cancelar'),
            ),
          ],
        );
        final actions = Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton.icon(
              onPressed: () => _perform(today.suggestedAction),
              icon: Icon(Icons.check_circle_outline, size: compact ? 24 : 30),
              label: Padding(
                padding: EdgeInsets.symmetric(vertical: compact ? 4 : 12),
                child: Text(
                  '${_actionLabel(today.suggestedAction)}  ·  $_countdown',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            for (final action in alternatives) ...[
              SizedBox(height: compact ? 8 : 14),
              OutlinedButton(
                onPressed: () => _perform(action),
                style: OutlinedButton.styleFrom(
                  minimumSize: Size(180, compact ? 48 : 58),
                  textStyle: TextStyle(
                    fontSize: compact ? 16 : 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: Text(_actionLabel(action), textAlign: TextAlign.center),
              ),
            ],
          ],
        );
        return _scrollableViewport(
          constraints: constraints,
          padding: EdgeInsets.all(compact ? 18 : 34),
          child: narrow
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [info, const SizedBox(height: 20), actions],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: info),
                    SizedBox(width: compact ? 22 : 36),
                    Expanded(child: actions),
                  ],
                ),
        );
      },
    );
  }

  Widget _result({required bool success}) => Container(
    key: ValueKey(success),
    color: success && _activeAction != null
        ? _actionColor(_activeAction!)
        : success
        ? Theme.of(context).colorScheme.primary
        : const Color(0xff8f1712),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 420;
        return _scrollableViewport(
          constraints: constraints,
          padding: EdgeInsets.all(compact ? 22 : 40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (success && _activeAction != null)
                _PunchActionAnimation(
                  action: _activeAction!,
                  processing: false,
                  size: compact ? 100 : 148,
                )
              else if (_cardRecognitionError)
                _UnrecognizedCardAnimation(width: compact ? 150 : 220)
              else
                Icon(
                  success ? Icons.check_circle : Icons.error_outline,
                  size: compact ? 72 : 110,
                  color: success ? Colors.black : Colors.white,
                ),
              SizedBox(height: compact ? 12 : 24),
              Text(
                _message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: success ? Colors.black : Colors.white,
                  fontSize: compact ? 28 : 38,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (success && _today != null) ...[
                SizedBox(height: compact ? 8 : 16),
                Text(
                  _farewellMessage(),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: success ? Colors.black87 : Colors.white,
                    fontSize: compact ? 18 : 22,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    ),
  );

  Widget _scrollableViewport({
    required BoxConstraints constraints,
    required EdgeInsets padding,
    required Widget child,
  }) => SingleChildScrollView(
    padding: padding,
    child: ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: constraints.maxWidth - padding.horizontal,
        minHeight: constraints.maxHeight - padding.vertical,
      ),
      child: IntrinsicHeight(child: child),
    ),
  );

  static String _friendly(Object error) => error is AppException
      ? error.message
      : 'Ha ocurrido un error. Inténtalo de nuevo.';
  static String _actionLabel(PunchAction action) => switch (action) {
    PunchAction.clockIn => 'FICHAR ENTRADA',
    PunchAction.clockOut => 'FICHAR SALIDA',
    PunchAction.pauseMeal => 'PAUSA COMIDA',
    PunchAction.pauseBreak => 'PAUSA DESCANSO',
    PunchAction.pauseEnd => 'FIN DE PAUSA',
  };
  static String _actionPast(PunchAction action) => switch (action) {
    PunchAction.clockIn => 'Entrada',
    PunchAction.clockOut => 'Salida',
    PunchAction.pauseMeal || PunchAction.pauseBreak => 'Pausa',
    PunchAction.pauseEnd => 'Fin de pausa',
  };
  static String _actionProgress(PunchAction action) => switch (action) {
    PunchAction.clockIn => 'Registrando tu entrada…',
    PunchAction.clockOut => 'Registrando tu salida…',
    PunchAction.pauseMeal => 'Iniciando pausa de comida…',
    PunchAction.pauseBreak => 'Iniciando descanso…',
    PunchAction.pauseEnd => 'Finalizando la pausa…',
  };

  static Color _actionColor(PunchAction action) => switch (action) {
    PunchAction.clockIn => const Color(0xffc6ff00),
    PunchAction.clockOut => const Color(0xff66dcff),
    PunchAction.pauseMeal => const Color(0xffffbd59),
    PunchAction.pauseBreak => const Color(0xffc4a7ff),
    PunchAction.pauseEnd => const Color(0xff72ffae),
  };

  String _farewellMessage() {
    final name = _today?.displayName ?? '';
    if (_activeAction == PunchAction.clockOut) {
      if (_completedAt?.weekday == DateTime.friday) {
        return '¡Que tengas un buen fin de semana, $name!';
      }
      return '¡Hasta mañana, $name!';
    }
    return '¡Que tengas un buen día, $name!';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clock?.cancel();
    _countdownTimer?.cancel();
    _recognitionTimer?.cancel();
    _readerWatchdog?.cancel();
    _cards?.cancel();
    widget.services.reader.stop();
    super.dispose();
  }
}

class _AnimatedNfcCard extends StatefulWidget {
  const _AnimatedNfcCard({required this.mode, required this.width});
  final _NfcCardAnimationMode mode;
  final double width;

  @override
  State<_AnimatedNfcCard> createState() => _AnimatedNfcCardState();
}

class _AnimatedNfcCardState extends State<_AnimatedNfcCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(
        milliseconds: widget.mode == _NfcCardAnimationMode.recognized
            ? 1050
            : 1500,
      ),
    );
    _start();
  }

  void _start() {
    if (widget.mode == _NfcCardAnimationMode.recognized) {
      _controller.forward(from: 0);
    } else {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant _AnimatedNfcCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mode != widget.mode) {
      _controller.duration = Duration(
        milliseconds: widget.mode == _NfcCardAnimationMode.recognized
            ? 1050
            : 1500,
      );
      _start();
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, child) {
      final value = Curves.easeInOutCubic.transform(_controller.value);
      final scanning = widget.mode == _NfcCardAnimationMode.scanning;
      final recognized = widget.mode == _NfcCardAnimationMode.recognized;
      final rotation = scanning ? value * math.pi * 2 : value * math.pi * 2;
      final scale = recognized
          ? 0.82 + (Curves.elasticOut.transform(value) * 0.18)
          : 0.96 + math.sin(value * math.pi * 2).abs() * 0.04;
      final glow = recognized
          ? (1 - (value - 0.72).abs()).clamp(0.25, 1.0)
          : 0.35 + math.sin(value * math.pi * 2).abs() * 0.45;

      return SizedBox(
        width: widget.width,
        height: widget.width * 0.68,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: widget.width * (0.72 + glow * 0.18),
              height: widget.width * (0.45 + glow * 0.12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                boxShadow: [
                  BoxShadow(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.18 + glow * 0.34),
                    blurRadius: 42 + glow * 25,
                    spreadRadius: glow * 8,
                  ),
                ],
              ),
            ),
            Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.0018)
                ..rotateX(scanning ? math.sin(value * math.pi * 2) * 0.10 : 0)
                ..rotateY(rotation),
              child: Transform.scale(scale: scale, child: child),
            ),
            if (recognized)
              Opacity(
                opacity: Curves.easeIn.transform(value),
                child: Align(
                  alignment: const Alignment(0.82, -0.78),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Theme.of(context).colorScheme.primary,
                      boxShadow: const [
                        BoxShadow(color: Colors.black54, blurRadius: 14),
                      ],
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      color: Colors.black,
                      size: 30,
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
    child: Image.asset(
      'assets/branding/worker_nfc_card.png',
      width: widget.width,
      filterQuality: FilterQuality.high,
      fit: BoxFit.contain,
    ),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

class _PunchActionAnimation extends StatefulWidget {
  const _PunchActionAnimation({
    required this.action,
    required this.processing,
    required this.size,
  });

  final PunchAction action;
  final bool processing;
  final double size;

  @override
  State<_PunchActionAnimation> createState() => _PunchActionAnimationState();
}

class _PunchActionAnimationState extends State<_PunchActionAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: widget.processing ? 1150 : 850),
    );
    if (widget.processing) {
      _controller.repeat();
    } else {
      _controller.forward();
    }
  }

  IconData get _icon => switch (widget.action) {
    PunchAction.clockIn => Icons.login_rounded,
    PunchAction.clockOut => Icons.logout_rounded,
    PunchAction.pauseMeal => Icons.restaurant_rounded,
    PunchAction.pauseBreak => Icons.coffee_rounded,
    PunchAction.pauseEnd => Icons.play_arrow_rounded,
  };

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, child) {
      final t = widget.processing
          ? _controller.value
          : Curves.elasticOut.transform(_controller.value);
      final wave = math.sin(t * math.pi * 2);
      final slide = switch (widget.action) {
        PunchAction.clockIn => Offset(-20 + t * 30, 0),
        PunchAction.clockOut => Offset(-8 + t * 30, 0),
        PunchAction.pauseMeal => Offset.zero,
        PunchAction.pauseBreak => Offset(0, -wave.abs() * 11),
        PunchAction.pauseEnd => Offset.zero,
      };
      final angle = switch (widget.action) {
        PunchAction.pauseMeal => wave * 0.13,
        PunchAction.pauseEnd when widget.processing => t * math.pi * 2,
        _ => 0.0,
      };
      final pulse = widget.action == PunchAction.pauseMeal
          ? 1 + wave.abs() * 0.10
          : widget.processing
          ? 0.94 + wave.abs() * 0.10
          : 0.72 + t * 0.28;
      final accent = _KioskScreenState._actionColor(widget.action);

      return SizedBox.square(
        dimension: widget.size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (widget.processing)
              SizedBox.square(
                dimension: widget.size,
                child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation(accent),
                  backgroundColor: Colors.white12,
                  strokeWidth: 5,
                ),
              ),
            Container(
              width: widget.size * 0.76,
              height: widget.size * 0.76,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.processing
                    ? const Color(0xff171a16)
                    : Colors.white,
                border: Border.all(color: accent, width: 4),
                boxShadow: [
                  BoxShadow(
                    color: accent.withValues(alpha: 0.45),
                    blurRadius: 28,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Transform.translate(
                offset: slide,
                child: Transform.rotate(
                  angle: angle,
                  child: Transform.scale(
                    scale: pulse,
                    child: Icon(
                      _icon,
                      size: widget.size * 0.40,
                      color: widget.processing ? accent : Colors.black,
                    ),
                  ),
                ),
              ),
            ),
            if (!widget.processing)
              Align(
                alignment: const Alignment(0.88, -0.82),
                child: Transform.scale(
                  scale: t.clamp(0.0, 1.0),
                  child: Container(
                    padding: EdgeInsets.all(widget.size * 0.045),
                    decoration: const BoxDecoration(
                      color: Colors.black,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.check_rounded,
                      color: accent,
                      size: widget.size * 0.20,
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

class _UnrecognizedCardAnimation extends StatefulWidget {
  const _UnrecognizedCardAnimation({required this.width});
  final double width;

  @override
  State<_UnrecognizedCardAnimation> createState() =>
      _UnrecognizedCardAnimationState();
}

class _UnrecognizedCardAnimationState extends State<_UnrecognizedCardAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 720),
    )..repeat();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, child) {
      final t = _controller.value;
      final shake = math.sin(t * math.pi * 6) * 8;
      return SizedBox(
        width: widget.width,
        height: widget.width * 0.68,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Transform.translate(
              offset: Offset(shake, 0),
              child: Opacity(opacity: 0.72, child: child),
            ),
            Positioned(
              top: 12 + t * widget.width * 0.42,
              left: widget.width * 0.10,
              right: widget.width * 0.10,
              child: Container(
                height: 3,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.redAccent,
                      blurRadius: 14,
                      spreadRadius: 4,
                    ),
                  ],
                ),
              ),
            ),
            Align(
              alignment: const Alignment(0.88, -0.80),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.question_mark_rounded,
                  color: Color(0xff8f1712),
                  size: 28,
                ),
              ),
            ),
          ],
        ),
      );
    },
    child: Image.asset(
      'assets/branding/worker_nfc_card.png',
      width: widget.width,
      filterQuality: FilterQuality.high,
      fit: BoxFit.contain,
    ),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
