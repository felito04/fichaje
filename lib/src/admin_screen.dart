import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'models.dart';
import 'nfc.dart';
import 'services.dart';

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key, required this.services});
  final AppServices services;

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  int _index = 0;
  bool _readerReady = false;
  bool _readerRestarting = false;

  @override
  void initState() {
    super.initState();
    widget.services.reader
        .start()
        .then((_) {
          if (mounted) setState(() => _readerReady = true);
        })
        .catchError((Object error) {
          if (mounted) _snack(_friendly(error));
        });
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      _ProgramCard(
        services: widget.services,
        readerReady: _readerReady,
        onOpenSettings: () => setState(() => _index = 2),
      ),
      _CardTools(services: widget.services, readerReady: _readerReady),
      _Settings(services: widget.services, readerReady: _readerReady),
      _Keys(services: widget.services),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Image.asset(
              'assets/branding/myurban_logo.png',
              height: 24,
              width: 284,
              fit: BoxFit.contain,
              alignment: Alignment.centerLeft,
            ),
            const SizedBox(width: 14),
            const Text('ADMIN', style: TextStyle(fontWeight: FontWeight.w800)),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: ActionChip(
              onPressed: _readerRestarting ? null : _restartReader,
              avatar: Icon(
                Icons.nfc,
                color: _readerReady
                    ? Theme.of(context).colorScheme.primary
                    : Colors.orange,
              ),
              label: Text(
                _readerRestarting
                    ? 'Reactivando…'
                    : _readerReady
                    ? 'NFC listo'
                    : 'Reactivar NFC',
              ),
            ),
          ),
          const SizedBox(width: 10),
          TextButton.icon(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.lock),
            label: const Text('Volver al quiosco'),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _index,
            extended: MediaQuery.sizeOf(context).width > 900,
            onDestinationSelected: (value) => setState(() => _index = value),
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.credit_card),
                label: Text('Programar'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.troubleshoot),
                label: Text('Probar / borrar'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.settings),
                label: Text('Configuración'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.key),
                label: Text('Claves'),
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: pages[_index]),
        ],
      ),
    );
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _restartReader() async {
    if (_readerRestarting) return;
    setState(() {
      _readerRestarting = true;
      _readerReady = false;
    });
    try {
      await widget.services.reader.restart();
      if (mounted) setState(() => _readerReady = true);
    } catch (error) {
      if (mounted) _snack(_friendly(error));
    } finally {
      if (mounted) setState(() => _readerRestarting = false);
    }
  }

  static String _friendly(Object error) => error is AppException
      ? error.message
      : 'Ha ocurrido un error inesperado.';

  @override
  void dispose() {
    widget.services.reader.stop();
    super.dispose();
  }
}

class _ProgramCard extends StatefulWidget {
  const _ProgramCard({
    required this.services,
    required this.readerReady,
    required this.onOpenSettings,
  });
  final AppServices services;
  final bool readerReady;
  final VoidCallback onOpenSettings;
  @override
  State<_ProgramCard> createState() => _ProgramCardState();
}

class _ProgramCardState extends State<_ProgramCard> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _capacityError = false;
  String? _status;
  String _programStep = 'preparación';

  Future<void> _program() async {
    if (!_form.currentState!.validate() || !widget.readerReady) return;
    setState(() {
      _busy = true;
      _capacityError = false;
      _programStep = 'validación de credenciales';
      _status = 'Comprobando las credenciales…';
    });
    try {
      final api = widget.services.api;
      final session = await api.login(_email.text.trim(), _password.text);
      final today = await api.today(session);
      if (today.userId == null) {
        throw const AppException(
          'El sistema no devolvió el identificador del usuario.',
        );
      }
      if (!mounted) return;
      setState(() {
        _programStep = 'detección de la tarjeta';
        _status = 'Acerca la tarjeta y mantenla apoyada en el lector…';
      });
      final card = await widget.services.reader.cards().first.timeout(
        const Duration(seconds: 30),
        onTimeout: () =>
            throw const AppException('No se detectó ninguna tarjeta.'),
      );
      final driver = await _chooseDriver(card);
      if (driver == null) throw const AppException('Programación cancelada.');
      final credentials = CardCredentials(
        email: _email.text.trim(),
        password: _password.text,
        userId: today.userId!,
      );
      _programStep = 'cifrado de las credenciales';
      final payload = await widget.services.codec.encode(credentials, card.uid);
      _programStep = 'comprobación del espacio disponible';
      if (payload.length > driver.capacityBytes(card)) {
        throw AppException(
          'El contenido no cabe en esta tarjeta (${payload.length}/${driver.capacityBytes(card)} bytes).',
          kind: AppErrorKind.capacity,
        );
      }
      setState(() {
        _programStep = 'escritura NFC';
        _status = 'Escribiendo… Mantén la tarjeta inmóvil y no la retires.';
      });
      await driver.writePayload(card, payload);
      if (mounted) {
        setState(() {
          _programStep = 'verificación de la escritura';
          _status = 'Verificando la tarjeta… No la retires todavía.';
        });
      }
      final reread = await driver.readPayload(card);
      if (reread == null) {
        throw const AppException('No se pudo verificar la escritura.');
      }
      final verified = await widget.services.codec.decode(reread, card.uid);
      if (verified.userId != today.userId) {
        throw const AppException('La verificación de la tarjeta no coincide.');
      }
      if (!mounted) return;
      setState(() => _status = 'Tarjeta de ${today.displayName} programada ✔');
      HapticFeedback.heavyImpact();
      _password.clear();
    } catch (error) {
      if (mounted) {
        setState(() {
          _capacityError =
              error is AppException && error.kind == AppErrorKind.capacity;
          _status = 'Error durante $_programStep: ${_friendly(error)}';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<CardDriver?> _chooseDriver(DetectedCard card) async {
    final drivers = widget.services.registry.supporting(card);
    if (drivers.isEmpty) {
      throw const AppException(
        'Este tipo de tarjeta todavía no es compatible.',
      );
    }
    if (drivers.length == 1) return drivers.first;
    if (!mounted) return null;
    return showDialog<CardDriver>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Elegir formato de tarjeta'),
        children: [
          for (final driver in drivers)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, driver),
              child: ListTile(
                title: Text(driver.id),
                subtitle: Text(
                  '${driver.capacityBytes(card)} bytes disponibles',
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(32),
    children: [
      Text(
        'Programar tarjeta',
        style: Theme.of(context).textTheme.headlineLarge,
      ),
      const SizedBox(height: 10),
      const Text(
        'Primero se validan las credenciales en el sistema. La contraseña solo se escribe cifrada en la tarjeta.',
        style: TextStyle(fontSize: 17),
      ),
      const SizedBox(height: 8),
      Text(
        'Sectores MIFARE permitidos: ${widget.services.config.mifareSectors.join(', ')}',
        style: TextStyle(
          fontSize: 15,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 12),
      const Card(
        child: ExpansionTile(
          leading: Icon(Icons.help_outline),
          title: Text('Cómo se programa una tarjeta'),
          childrenPadding: EdgeInsets.fromLTRB(20, 0, 20, 18),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('1. La app valida el email y la contraseña en el sistema.'),
            SizedBox(height: 6),
            Text(
              '2. Al acercar la tarjeta, detecta su UID y busca espacio libre.',
            ),
            SizedBox(height: 6),
            Text(
              '3. Cifra las credenciales ligándolas a ese UID y las escribe.',
            ),
            SizedBox(height: 6),
            Text('4. Lee de nuevo la tarjeta para comprobar que quedó bien.'),
            SizedBox(height: 10),
            Text(
              'Mantén la tarjeta inmóvil contra el lector hasta ver la confirmación.',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      Form(
        key: _form,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Column(
            children: [
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.username],
                decoration: const InputDecoration(
                  labelText: 'Email del sistema',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => value != null && value.contains('@')
                    ? null
                    : 'Introduce un email válido.',
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _password,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Contraseña',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => value == null || value.isEmpty
                    ? 'Introduce la contraseña.'
                    : null,
              ),
              const SizedBox(height: 22),
              FilledButton.icon(
                onPressed: _busy || !widget.readerReady ? null : _program,
                icon: const Icon(Icons.nfc),
                label: Text(
                  widget.readerReady
                      ? 'Validar y programar'
                      : 'Preparando NFC…',
                ),
              ),
            ],
          ),
        ),
      ),
      if (_status != null)
        Padding(
          padding: const EdgeInsets.only(top: 24),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  if (_busy) ...[
                    const CircularProgressIndicator(),
                    const SizedBox(width: 18),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_status!, style: const TextStyle(fontSize: 18)),
                        if (_capacityError) ...[
                          const SizedBox(height: 8),
                          const Text(
                            'Usa “Probar tarjeta” para ver qué sectores están libres. Después añade únicamente sectores libres a la configuración.',
                          ),
                          const SizedBox(height: 10),
                          OutlinedButton.icon(
                            onPressed: widget.onOpenSettings,
                            icon: const Icon(Icons.settings),
                            label: const Text('Cambiar sectores permitidos'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
    ],
  );

  static String _friendly(Object error) {
    if (error is AppException) return error.message;
    if (error is PlatformException) {
      final detail = error.message?.trim() ?? '';
      final normalized = detail.toLowerCase();
      if ((normalized.contains('tag') && normalized.contains('lost')) ||
          normalized.contains('transceive')) {
        return 'Se perdió el contacto NFC. Mantén la tarjeta completamente inmóvil sobre el lector hasta terminar.';
      }
      if (normalized.contains('auth')) {
        return 'El lector no pudo autenticar uno de los sectores elegidos. Vuelve a ejecutar “Probar tarjeta”.';
      }
      return detail.isEmpty
          ? 'El lector NFC devolvió el error ${error.code}.'
          : 'Error NFC ${error.code}: $detail';
    }
    if (error is TimeoutException) {
      return 'Se agotó el tiempo de espera. Acerca de nuevo la tarjeta.';
    }
    return 'Fallo interno ${error.runtimeType}. Vuelve a intentarlo manteniendo la tarjeta inmóvil.';
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }
}

class _CardTools extends StatefulWidget {
  const _CardTools({required this.services, required this.readerReady});
  final AppServices services;
  final bool readerReady;
  @override
  State<_CardTools> createState() => _CardToolsState();
}

class _CardToolsState extends State<_CardTools> {
  bool _busy = false;
  String? _title;
  List<String> _lines = const [];

  Future<DetectedCard> _nextCard() =>
      widget.services.reader.cards().first.timeout(
        const Duration(seconds: 30),
        onTimeout: () =>
            throw const AppException('No se detectó ninguna tarjeta.'),
      );

  Future<void> _diagnose() async {
    setState(() {
      _busy = true;
      _title = 'Acerca la tarjeta…';
      _lines = const [];
    });
    try {
      final card = await _nextCard();
      final drivers = widget.services.registry.supporting(card);
      final lines = <String>[
        'UID: ${card.uidHex}',
        'Tecnologías: ${card.technologies.join(', ')}',
      ];
      if (drivers.isEmpty) lines.add('Ningún driver compatible.');
      for (final driver in drivers) {
        final diagnostic = await driver.diagnose(card);
        lines.addAll([
          '',
          'Driver: ${diagnostic.driverId}',
          'Capacidad útil: ${diagnostic.capacity} bytes',
          'Sobre MUSF: ${diagnostic.hasPayload ? 'sí' : 'no'}',
          ...diagnostic.details,
        ]);
        if (diagnostic.hasPayload) {
          try {
            final payload = await driver.readPayload(card);
            final credentials = await widget.services.codec.decode(
              payload!,
              card.uid,
            );
            final session = await widget.services.api.login(
              credentials.email,
              credentials.password,
            );
            final today = await widget.services.api.today(session);
            lines.add('Titular: ${today.displayName}');
          } catch (error) {
            lines.add('Contenido: ${_friendly(error)}');
          }
        }
      }
      if (mounted) {
        setState(() {
          _title = 'Diagnóstico';
          _lines = lines;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _title = _friendly(error);
          _lines = const [];
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _erase() async {
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Borrar tarjeta'),
            content: const Text(
              'Solo se borrarán los datos de esta app. Los sectores ajenos no se tocarán.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Borrar'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    setState(() {
      _busy = true;
      _title = 'Acerca la tarjeta…';
      _lines = const [];
    });
    try {
      final card = await _nextCard();
      var erased = 0;
      for (final driver in widget.services.registry.supporting(card)) {
        if (await driver.ownsStorage(card)) {
          await driver.erasePayload(card);
          erased++;
        }
      }
      if (mounted) {
        setState(
          () => _title = erased > 0
              ? 'Tarjeta borrada ✔'
              : 'La tarjeta no contenía datos de esta app.',
        );
      }
    } catch (error) {
      if (mounted) setState(() => _title = _friendly(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(32),
    children: [
      Text(
        'Probar tarjeta y lector',
        style: Theme.of(context).textTheme.headlineLarge,
      ),
      const SizedBox(height: 12),
      const Text(
        'Comprueba compatibilidad, UID, capacidad y el mapa completo de sectores 1–15. El diagnóstico no escribe nada.',
        style: TextStyle(fontSize: 17),
      ),
      const SizedBox(height: 26),
      Wrap(
        spacing: 14,
        children: [
          FilledButton.icon(
            onPressed: _busy || !widget.readerReady ? null : _diagnose,
            icon: const Icon(Icons.troubleshoot),
            label: const Text('Probar tarjeta'),
          ),
          OutlinedButton.icon(
            onPressed: _busy || !widget.readerReady ? null : _erase,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Borrar datos de fichaje'),
          ),
        ],
      ),
      if (_title != null)
        Card(
          margin: const EdgeInsets.only(top: 26),
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (_busy) ...[
                      const CircularProgressIndicator(),
                      const SizedBox(width: 18),
                    ],
                    Expanded(
                      child: Text(
                        _title!,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                  ],
                ),
                for (final line in _lines)
                  Padding(
                    padding: const EdgeInsets.only(top: 7),
                    child: SelectableText(
                      line,
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
              ],
            ),
          ),
        ),
    ],
  );

  static String _friendly(Object error) =>
      error is AppException ? error.message : 'No se pudo leer la tarjeta.';
}

class _Settings extends StatefulWidget {
  const _Settings({required this.services, required this.readerReady});
  final AppServices services;
  final bool readerReady;
  @override
  State<_Settings> createState() => _SettingsState();
}

class _SettingsState extends State<_Settings> {
  late final TextEditingController _url, _tablet, _sectors, _lat, _lng, _newPin;
  late bool _biometricAdminEnabled;
  bool _busy = false;
  String? _formatStatus;

  @override
  void initState() {
    super.initState();
    final c = widget.services.config;
    _url = TextEditingController(text: c.baseUrl);
    _tablet = TextEditingController(text: c.tabletId);
    _sectors = TextEditingController(text: c.mifareSectors.join(','));
    _lat = TextEditingController(text: c.latitude?.toString() ?? '');
    _lng = TextEditingController(text: c.longitude?.toString() ?? '');
    _newPin = TextEditingController();
    _biometricAdminEnabled = c.biometricAdminEnabled;
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final uri = Uri.tryParse(_url.text.trim());
      if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
        throw const AppException('La URL del backend no es válida.');
      }
      final sectors = _sectors.text
          .split(',')
          .map((value) => int.tryParse(value.trim()))
          .toList();
      if (sectors.any((value) => value == null || value < 1 || value > 15) ||
          sectors.toSet().length != sectors.length ||
          sectors.isEmpty) {
        throw const AppException(
          'Los sectores deben ser números únicos entre 1 y 15.',
        );
      }
      final hasLat = _lat.text.trim().isNotEmpty,
          hasLng = _lng.text.trim().isNotEmpty;
      if (hasLat != hasLng) {
        throw const AppException(
          'Indica latitud y longitud, o deja ambas vacías.',
        );
      }
      final lat = hasLat ? double.tryParse(_lat.text.trim()) : null,
          lng = hasLng ? double.tryParse(_lng.text.trim()) : null;
      if (hasLat &&
          (lat == null ||
              lng == null ||
              lat < -90 ||
              lat > 90 ||
              lng < -180 ||
              lng > 180)) {
        throw const AppException('Las coordenadas no son válidas.');
      }
      await widget.services.updateConfig(
        AppConfig(
          baseUrl: _url.text.trim(),
          tabletId: _tablet.text.trim(),
          mifareSectors: sectors.cast<int>(),
          biometricAdminEnabled: _biometricAdminEnabled,
          latitude: lat,
          longitude: lng,
        ),
      );
      if (_newPin.text.isNotEmpty) {
        await widget.services.pinStore.setPin(_newPin.text);
        _newPin.clear();
      }
      if (mounted) _snack('Configuración guardada.');
    } catch (error) {
      if (mounted) {
        _snack(error is AppException ? error.message : 'No se pudo guardar.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _test() async {
    setState(() => _busy = true);
    try {
      await _save();
      await widget.services.api.testConnection();
      if (mounted) _snack('Backend accesible ✔');
    } catch (error) {
      if (mounted) {
        _snack(error is AppException ? error.message : 'No se pudo conectar.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _formatCard() async {
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            icon: const Icon(Icons.warning_amber_rounded),
            title: const Text('Formatear tarjeta NFC'),
            content: Text(
              'Se borrarán los datos NFC que se puedan escribir. En MIFARE '
              'solo se vaciarán los sectores configurados '
              '(${widget.services.config.mifareSectors.join(', ')}) y nunca '
              'el sector 0.\n\nEsta acción puede borrar datos de otros sistemas. '
              'Úsala únicamente en tarjetas destinadas al fichaje.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancelar'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(context, true),
                icon: const Icon(Icons.format_clear),
                label: const Text('Formatear'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !widget.readerReady) return;
    setState(() {
      _busy = true;
      _formatStatus = 'Acerca la tarjeta y mantenla inmóvil…';
    });
    try {
      final card = await widget.services.reader.cards().first.timeout(
        const Duration(seconds: 30),
        onTimeout: () =>
            throw const AppException('No se detectó ninguna tarjeta.'),
      );
      if (mounted) {
        setState(() => _formatStatus = 'Formateando… No retires la tarjeta.');
      }
      final driver = widget.services.registry.writerFor(card);
      final result = await driver.formatStorage(card);
      if (result.formattedUnits == 0) {
        throw const AppException(
          'No se pudo liberar ningún sector. La tarjeta puede usar claves de '
          'otro sistema o estar bloqueada contra escritura.',
        );
      }
      if (!mounted) return;
      final unit = result.driverId == 'mifare_classic'
          ? result.formattedUnits == 1
                ? 'sector'
                : 'sectores'
          : 'área NDEF';
      setState(() {
        _formatStatus = result.skippedUnits == 0
            ? 'Tarjeta formateada ✔ · ${result.formattedUnits} $unit liberados.'
            : 'Formato parcial: ${result.formattedUnits} $unit liberados y '
                  '${result.skippedUnits} sectores protegidos/no accesibles.';
      });
      HapticFeedback.heavyImpact();
    } catch (error) {
      if (mounted) {
        setState(
          () => _formatStatus = error is AppException
              ? error.message
              : 'No se pudo formatear la tarjeta.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(32),
    children: [
      Text('Configuración', style: Theme.of(context).textTheme.headlineLarge),
      const SizedBox(height: 24),
      _field(
        _url,
        'URL base del sistema',
        helper: 'Usa staging para todas las pruebas antes de producción.',
      ),
      _field(_tablet, 'Identificador de la tablet'),
      _field(
        _sectors,
        'Sectores MIFARE permitidos',
        helper:
            'Separados por comas. Añade solo sectores marcados como libres en “Probar tarjeta”. El sector 0 nunca se admite.',
      ),
      Row(
        children: [
          Expanded(
            child: _field(_lat, 'Latitud fija (opcional)', number: true),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: _field(_lng, 'Longitud fija (opcional)', number: true),
          ),
        ],
      ),
      _field(_newPin, 'Cambiar PIN (4–8 cifras)', number: true, obscure: true),
      Card(
        margin: const EdgeInsets.only(bottom: 18),
        child: SwitchListTile(
          value: _biometricAdminEnabled,
          onChanged: _busy
              ? null
              : (value) => setState(() => _biometricAdminEnabled = value),
          secondary: const Icon(Icons.fingerprint),
          title: const Text('Biometría para administración'),
          subtitle: const Text(
            'Permite entrar con huella, rostro u otro biométrico configurado. '
            'El PIN seguirá disponible como alternativa.',
          ),
        ),
      ),
      Wrap(
        spacing: 14,
        children: [
          FilledButton.icon(
            onPressed: _busy ? null : _save,
            icon: const Icon(Icons.save),
            label: const Text('Guardar'),
          ),
          OutlinedButton.icon(
            onPressed: _busy ? null : _test,
            icon: const Icon(Icons.cloud_done),
            label: const Text('Guardar y probar conexión'),
          ),
        ],
      ),
      const SizedBox(height: 28),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Preparar una tarjeta usada',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text(
                'Si una tarjeta contiene datos anteriores y no quedan sectores '
                'libres, puedes vaciarla antes de programarla.',
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _busy || !widget.readerReady ? null : _formatCard,
                icon: const Icon(Icons.format_clear),
                label: const Text('Formatear tarjeta NFC'),
              ),
              if (_formatStatus != null) ...[
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_busy) ...[
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Expanded(child: Text(_formatStatus!)),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    ],
  );

  Widget _field(
    TextEditingController controller,
    String label, {
    String? helper,
    bool number = false,
    bool obscure = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: number
          ? const TextInputType.numberWithOptions(decimal: true, signed: true)
          : TextInputType.text,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        border: const OutlineInputBorder(),
      ),
    ),
  );
  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  @override
  void dispose() {
    for (final c in [_url, _tablet, _sectors, _lat, _lng, _newPin]) {
      c.dispose();
    }
    super.dispose();
  }
}

class _Keys extends StatefulWidget {
  const _Keys({required this.services});
  final AppServices services;
  @override
  State<_Keys> createState() => _KeysState();
}

class _KeysState extends State<_Keys> {
  String? _bundle;
  bool _busy = false;

  Future<void> _export() async {
    final bundle = await widget.services.keyVault.exportBundle();
    if (mounted) setState(() => _bundle = bundle);
  }

  Future<void> _rotate() async {
    final yes =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Rotar clave'),
            content: const Text(
              'Las claves anteriores se conservarán para leer tarjetas existentes. Las tarjetas nuevas usarán la clave nueva.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Rotar'),
              ),
            ],
          ),
        ) ??
        false;
    if (!yes) return;
    final id = await widget.services.keyVault.rotate();
    if (mounted) {
      setState(() => _bundle = null);
      _snack('Clave $id creada. Exporta un QR de respaldo.');
    }
  }

  Future<void> _scan() async {
    final value = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const _QrScanner()),
    );
    if (value == null) return;
    setState(() => _busy = true);
    try {
      await widget.services.keyVault.importBundle(value);
      if (mounted) _snack('Claves importadas correctamente.');
    } catch (error) {
      if (mounted) {
        _snack(
          error is AppException
              ? error.message
              : 'No se pudieron importar las claves.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(32),
    children: [
      Text(
        'Claves de cifrado',
        style: Theme.of(context).textTheme.headlineLarge,
      ),
      const SizedBox(height: 12),
      const Text(
        'El QR contiene material secreto: muéstralo solo en un entorno seguro y no hagas capturas.',
        style: TextStyle(fontSize: 17),
      ),
      const SizedBox(height: 24),
      Wrap(
        spacing: 14,
        children: [
          FilledButton.icon(
            onPressed: _busy ? null : _export,
            icon: const Icon(Icons.qr_code),
            label: const Text('Exportar QR'),
          ),
          OutlinedButton.icon(
            onPressed: _busy ? null : _scan,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Importar QR'),
          ),
          OutlinedButton.icon(
            onPressed: _busy ? null : _rotate,
            icon: const Icon(Icons.sync_lock),
            label: const Text('Rotar clave'),
          ),
        ],
      ),
      if (_bundle != null)
        Center(
          child: Card(
            margin: const EdgeInsets.only(top: 26),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  QrImageView(
                    data: _bundle!,
                    size: 320,
                    backgroundColor: Colors.white,
                    eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: Colors.black,
                    ),
                    dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: Colors.black,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Copia de seguridad de claves MUSF',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ),
        ),
    ],
  );
  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

class _QrScanner extends StatefulWidget {
  const _QrScanner();
  @override
  State<_QrScanner> createState() => _QrScannerState();
}

class _QrScannerState extends State<_QrScanner> {
  bool _done = false;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Escanear clave')),
    body: MobileScanner(
      onDetect: (capture) {
        if (_done || capture.barcodes.isEmpty) return;
        final value = capture.barcodes.first.rawValue;
        if (value != null && value.startsWith('MUSFKEY1:')) {
          _done = true;
          Navigator.pop(context, value);
        }
      },
    ),
  );
}
