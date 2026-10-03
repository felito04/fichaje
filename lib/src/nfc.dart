import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ndef_record/ndef_record.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';

import 'models.dart';
import 'security.dart';

abstract class NfcReader {
  String get id;
  Future<bool> isAvailable();
  Stream<DetectedCard> cards();
  Future<void> start();
  Future<void> stop();
  Future<void> restart();
}

class InternalAndroidReader implements NfcReader {
  final _controller = StreamController<DetectedCard>.broadcast();
  bool _started = false;

  @override
  String get id => 'internal';

  @override
  Future<bool> isAvailable() async =>
      await NfcManager.instance.checkAvailability() == NfcAvailability.enabled;

  @override
  Stream<DetectedCard> cards() => _controller.stream;

  @override
  Future<void> start() async {
    if (_started) return;
    if (!await isAvailable()) {
      throw const AppException(
        'NFC no está disponible o está desactivado en esta tablet.',
      );
    }
    try {
      await NfcManager.instance.startSession(
        pollingOptions: const {NfcPollingOption.iso14443},
        noPlatformSoundsAndroid: true,
        onDiscovered: (tag) {
          final android = NfcTagAndroid.from(tag);
          if (android == null) return;
          _controller.add(
            DetectedCard(
              uid: android.id,
              technologies: android.techList.toSet(),
              handle: tag,
            ),
          );
        },
      );
      _started = true;
    } catch (_) {
      _started = false;
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    await NfcManager.instance.stopSession();
  }

  @override
  Future<void> restart() async {
    if (_started) {
      _started = false;
      try {
        await NfcManager.instance.stopSession();
      } catch (_) {
        // The Android NFC service may already have dropped the reader session.
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await start();
  }
}

abstract class CardDriver {
  String get id;
  int get priority;
  bool supports(DetectedCard card);
  int capacityBytes(DetectedCard card);
  Future<Uint8List?> readPayload(DetectedCard card);
  Future<void> writePayload(DetectedCard card, Uint8List payload);
  Future<void> erasePayload(DetectedCard card);
  Future<bool> ownsStorage(DetectedCard card);
  Future<CardDiagnostic> diagnose(DetectedCard card);
}

class CardDiagnostic {
  const CardDiagnostic({
    required this.driverId,
    required this.capacity,
    required this.details,
    required this.hasPayload,
  });
  final String driverId;
  final int capacity;
  final List<String> details;
  final bool hasPayload;
}

class CardReadResult {
  const CardReadResult({required this.driver, required this.payload});
  final CardDriver driver;
  final Uint8List payload;
}

class CardDriverRegistry {
  CardDriverRegistry(Iterable<CardDriver> drivers)
    : _drivers = [...drivers]..sort((a, b) => b.priority.compareTo(a.priority));
  final List<CardDriver> _drivers;
  List<CardDriver> supporting(DetectedCard card) =>
      _drivers.where((driver) => driver.supports(card)).toList();

  Future<CardReadResult> read(DetectedCard card) async {
    final compatibleDrivers = supporting(card);
    if (compatibleDrivers.isEmpty) {
      throw const AppException(
        'Este tipo de tarjeta NFC no es compatible con la tablet.',
        kind: AppErrorKind.invalidCard,
      );
    }
    for (final driver in compatibleDrivers) {
      final payload = await driver.readPayload(card);
      if (payload != null) {
        return CardReadResult(driver: driver, payload: payload);
      }
    }
    throw const AppException(
      'Esta tarjeta todavía no está configurada para fichar. Usa “Configurar tarjetas” para programarla.',
      kind: AppErrorKind.invalidCard,
    );
  }

  CardDriver writerFor(DetectedCard card, {String? driverId}) {
    final drivers = supporting(card);
    if (driverId != null) {
      return drivers.firstWhere(
        (driver) => driver.id == driverId,
        orElse: () => throw const AppException(
          'El driver elegido no admite esta tarjeta.',
        ),
      );
    }
    if (drivers.isEmpty) {
      throw const AppException(
        'Este tipo de tarjeta todavía no es compatible.',
      );
    }
    return drivers.first;
  }
}

class NdefDriver implements CardDriver {
  NdefDriver({required this.vault});
  final KeyVault vault;
  static const mimeType = 'application/vnd.myurbanscoot.fichaje';
  static final _mimeBytes = Uint8List.fromList(ascii.encode(mimeType));

  @override
  String get id => 'ndef';
  @override
  int get priority => 100;
  @override
  bool supports(DetectedCard card) =>
      NdefAndroid.from(card.handle as NfcTag) != null;
  @override
  int capacityBytes(DetectedCard card) =>
      (NdefAndroid.from(card.handle as NfcTag)?.maxSize ?? 0) - 48;

  @override
  Future<Uint8List?> readPayload(DetectedCard card) async {
    final ndef = NdefAndroid.from(card.handle as NfcTag);
    if (ndef == null) return null;
    final message = await ndef.getNdefMessage();
    if (message == null) return null;
    for (final record in message.records) {
      if (record.typeNameFormat == TypeNameFormat.media &&
          _bytesEqual(record.type, _mimeBytes)) {
        return record.payload;
      }
    }
    return null;
  }

  @override
  Future<void> writePayload(DetectedCard card, Uint8List payload) async {
    final ndef = NdefAndroid.from(card.handle as NfcTag);
    if (ndef == null || !ndef.isWritable) {
      throw const AppException('La tarjeta NDEF no permite escritura.');
    }
    final ntag = await _detectNtag(card);
    if (ntag != null) await _disableOwnedProtection(card, ntag);
    final message = NdefMessage(
      records: [
        NdefRecord(
          typeNameFormat: TypeNameFormat.media,
          type: _mimeBytes,
          identifier: Uint8List(0),
          payload: payload,
        ),
      ],
    );
    if (message.byteLength > ndef.maxSize) {
      throw AppException(
        'El contenido no cabe en esta tarjeta (${message.byteLength}/${ndef.maxSize} bytes).',
        kind: AppErrorKind.capacity,
      );
    }
    await ndef.writeNdefMessage(message);
    if (ntag != null) await _enableProtection(card, ntag);
  }

  @override
  Future<void> erasePayload(DetectedCard card) async {
    final ndef = NdefAndroid.from(card.handle as NfcTag);
    if (ndef == null || !ndef.isWritable) {
      throw const AppException('La tarjeta NDEF no permite escritura.');
    }
    final ntag = await _detectNtag(card);
    if (ntag != null) await _disableOwnedProtection(card, ntag);
    await ndef.writeNdefMessage(const NdefMessage(records: []));
  }

  @override
  Future<bool> ownsStorage(DetectedCard card) async =>
      await readPayload(card) != null;

  @override
  Future<CardDiagnostic> diagnose(DetectedCard card) async {
    final ndef = NdefAndroid.from(card.handle as NfcTag)!;
    final ntag = await _detectNtag(card);
    return CardDiagnostic(
      driverId: id,
      capacity: capacityBytes(card),
      hasPayload: await readPayload(card) != null,
      details: [
        'Tipo: ${ndef.type}',
        'Capacidad NDEF: ${ndef.maxSize} bytes',
        ndef.isWritable ? 'Escritura permitida' : 'Solo lectura',
        if (ntag != null)
          'Modelo: ${ntag.name} (protección por contraseña compatible)',
      ],
    );
  }

  Future<_NtagLayout?> _detectNtag(DetectedCard card) async {
    final nfcA = NfcAAndroid.from(card.handle as NfcTag);
    if (nfcA == null) return null;
    try {
      final version = await nfcA.transceive(Uint8List.fromList([0x60]));
      if (version.length < 8 || version[1] != 0x04) return null;
      return switch (version[6]) {
        0x0f => const _NtagLayout(
          'NTAG213',
          configPage: 0x29,
          passwordPage: 0x2b,
          packPage: 0x2c,
        ),
        0x11 => const _NtagLayout(
          'NTAG215',
          configPage: 0x83,
          passwordPage: 0x85,
          packPage: 0x86,
        ),
        0x13 => const _NtagLayout(
          'NTAG216',
          configPage: 0xe3,
          passwordPage: 0xe5,
          packPage: 0xe6,
        ),
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }

  Future<void> _disableOwnedProtection(
    DetectedCard card,
    _NtagLayout layout,
  ) async {
    final nfcA = NfcAAndroid.from(card.handle as NfcTag)!;
    for (final keyId in await vault.installedKeyIds()) {
      final protection = await vault.deriveNtagProtection(
        card.uid,
        keyId: keyId,
      );
      try {
        final response = await nfcA.transceive(
          Uint8List.fromList([0x1b, ...protection.sublist(0, 4)]),
        );
        if (response.length >= 2 &&
            _bytesEqual(response.sublist(0, 2), protection.sublist(4, 6))) {
          final config = await nfcA.transceive(
            Uint8List.fromList([0x30, layout.configPage]),
          );
          if (config.length < 4) {
            throw const AppException('No se pudo leer la configuración NTAG.');
          }
          await _writePage(
            nfcA,
            layout.configPage,
            Uint8List.fromList([config[0], config[1], config[2], 0xff]),
          );
          return;
        }
      } catch (_) {
        // An unprotected/new tag rejects PWD_AUTH; the following NDEF write remains valid.
      }
    }
  }

  Future<void> _enableProtection(DetectedCard card, _NtagLayout layout) async {
    final nfcA = NfcAAndroid.from(card.handle as NfcTag)!;
    final protection = await vault.deriveNtagProtection(card.uid);
    await _writePage(nfcA, layout.passwordPage, protection.sublist(0, 4));
    await _writePage(
      nfcA,
      layout.packPage,
      Uint8List.fromList([protection[4], protection[5], 0x00, 0x00]),
    );
    final config = await nfcA.transceive(
      Uint8List.fromList([0x30, layout.configPage]),
    );
    if (config.length < 4) {
      throw const AppException('No se pudo leer la configuración NTAG.');
    }
    // AUTH0=04 protects writes from the first user-memory page. ACCESS.PROT stays 0,
    // so reads remain public while writes require PWD_AUTH.
    await _writePage(
      nfcA,
      layout.configPage,
      Uint8List.fromList([config[0], config[1], config[2], 0x04]),
    );
  }

  Future<void> _writePage(NfcAAndroid nfcA, int page, List<int> data) async {
    final response = await nfcA.transceive(
      Uint8List.fromList([0xa2, page, ...data]),
    );
    if (response.isEmpty || response.first != 0x0a) {
      throw const AppException(
        'La tarjeta NTAG rechazó la protección de escritura.',
      );
    }
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _NtagLayout {
  const _NtagLayout(
    this.name, {
    required this.configPage,
    required this.passwordPage,
    required this.packPage,
  });
  final String name;
  final int configPage;
  final int passwordPage;
  final int packPage;
}

enum MifareSectorState { free, appOwned, occupied }

class MifareClassicDriver implements CardDriver {
  MifareClassicDriver({required this.vault, required List<int> sectors})
    : sectors = [...sectors]..sort();
  final KeyVault vault;
  final List<int> sectors;
  static final _factoryKey = Uint8List.fromList(List.filled(6, 0xff));
  static final _access = Uint8List.fromList([0xff, 0x07, 0x80, 0x69]);

  @override
  String get id => 'mifare_classic';
  @override
  int get priority => 200;
  @override
  bool supports(DetectedCard card) {
    final tag = MifareClassicAndroid.from(card.handle as NfcTag);
    return tag != null && tag.sectorCount == 16;
  }

  @override
  int capacityBytes(DetectedCard card) => sectors.length * 48;

  Future<_SectorAccess> _accessFor(
    MifareClassicAndroid tag,
    int sector,
    Uint8List uid,
  ) async {
    for (final keyId in await vault.installedKeyIds()) {
      final keyA = await vault.deriveMifareKey(uid, keyA: true, keyId: keyId);
      if (await tag.authenticateSectorWithKeyA(
        sectorIndex: sector,
        key: keyA,
      )) {
        return _SectorAccess(MifareSectorState.appOwned, keyId);
      }
    }
    if (await tag.authenticateSectorWithKeyA(
      sectorIndex: sector,
      key: _factoryKey,
    )) {
      final data = <int>[];
      for (var block = sector * 4; block < sector * 4 + 3; block++) {
        data.addAll(await tag.readBlock(blockIndex: block));
      }
      final empty =
          data.every((byte) => byte == 0x00) ||
          data.every((byte) => byte == 0xff);
      return _SectorAccess(
        empty ? MifareSectorState.free : MifareSectorState.occupied,
        null,
      );
    }
    return const _SectorAccess(MifareSectorState.occupied, null);
  }

  @override
  Future<Uint8List?> readPayload(DetectedCard card) async {
    final tag = MifareClassicAndroid.from(card.handle as NfcTag);
    if (tag == null) return null;
    final bytes = <int>[];
    for (final sector in sectors) {
      final access = await _accessFor(tag, sector, card.uid);
      if (access.state != MifareSectorState.appOwned) continue;
      final keyA = await vault.deriveMifareKey(
        card.uid,
        keyA: true,
        keyId: access.keyId,
      );
      if (!await tag.authenticateSectorWithKeyA(
        sectorIndex: sector,
        key: keyA,
      )) {
        continue;
      }
      for (var block = sector * 4; block < sector * 4 + 3; block++) {
        bytes.addAll(await tag.readBlock(blockIndex: block));
      }
    }
    if (bytes.length < CredentialCodec.headerLength ||
        ascii.decode(bytes.sublist(0, 4), allowInvalid: true) != 'MUSF') {
      return null;
    }
    final length = (bytes[6] << 8) | bytes[7];
    final total = CredentialCodec.headerLength + length;
    if (total > bytes.length) {
      throw const AppException(
        'La tarjeta contiene datos incompletos.',
        kind: AppErrorKind.invalidCard,
      );
    }
    return Uint8List.fromList(bytes.sublist(0, total));
  }

  @override
  Future<void> writePayload(DetectedCard card, Uint8List payload) async {
    final tag = MifareClassicAndroid.from(card.handle as NfcTag);
    if (tag == null) {
      throw const AppException('La tarjeta no es MIFARE Classic 1K.');
    }
    final needed = (payload.length / 48).ceil();
    final writable = <int>[];
    for (final sector in sectors) {
      final access = await _accessFor(tag, sector, card.uid);
      if (access.state == MifareSectorState.free ||
          access.state == MifareSectorState.appOwned) {
        writable.add(sector);
      }
    }
    if (writable.length < needed) {
      throw AppException(
        'No hay suficientes sectores libres: hacen falta $needed y hay ${writable.length}.',
        kind: AppErrorKind.capacity,
      );
    }
    final selected = writable.take(needed).toList()..sort();
    final padded = Uint8List(needed * 48)..setAll(0, payload);
    final currentId = await vault.currentKeyId;
    final keyA = await vault.deriveMifareKey(
      card.uid,
      keyA: true,
      keyId: currentId,
    );
    final keyB = await vault.deriveMifareKey(
      card.uid,
      keyA: false,
      keyId: currentId,
    );
    final trailer = Uint8List.fromList([...keyA, ..._access, ...keyB]);
    _validateTrailer(trailer);

    for (var index = 0; index < selected.length; index++) {
      final sector = selected[index];
      final access = await _accessFor(tag, sector, card.uid);
      final authKey = access.state == MifareSectorState.free
          ? _factoryKey
          : await vault.deriveMifareKey(
              card.uid,
              keyA: true,
              keyId: access.keyId,
            );
      if (!await tag.authenticateSectorWithKeyA(
        sectorIndex: sector,
        key: authKey,
      )) {
        throw AppException('No se pudo autenticar el sector $sector.');
      }
      for (var dataBlock = 0; dataBlock < 3; dataBlock++) {
        final offset = index * 48 + dataBlock * 16;
        await tag.writeBlock(
          blockIndex: sector * 4 + dataBlock,
          data: Uint8List.fromList(padded.sublist(offset, offset + 16)),
        );
      }
      await tag.writeBlock(blockIndex: sector * 4 + 3, data: trailer);
    }
  }

  @override
  Future<void> erasePayload(DetectedCard card) async {
    final tag = MifareClassicAndroid.from(card.handle as NfcTag);
    if (tag == null) {
      throw const AppException('La tarjeta no es MIFARE Classic 1K.');
    }
    final factoryTrailer = Uint8List.fromList([
      ..._factoryKey,
      ..._access,
      ..._factoryKey,
    ]);
    _validateTrailer(factoryTrailer);
    for (final sector in sectors) {
      final access = await _accessFor(tag, sector, card.uid);
      if (access.state != MifareSectorState.appOwned) continue;
      final keyA = await vault.deriveMifareKey(
        card.uid,
        keyA: true,
        keyId: access.keyId,
      );
      if (!await tag.authenticateSectorWithKeyA(
        sectorIndex: sector,
        key: keyA,
      )) {
        continue;
      }
      for (var dataBlock = 0; dataBlock < 3; dataBlock++) {
        await tag.writeBlock(
          blockIndex: sector * 4 + dataBlock,
          data: Uint8List(16),
        );
      }
      await tag.writeBlock(blockIndex: sector * 4 + 3, data: factoryTrailer);
    }
  }

  @override
  Future<bool> ownsStorage(DetectedCard card) async {
    final tag = MifareClassicAndroid.from(card.handle as NfcTag);
    if (tag == null) return false;
    for (final sector in sectors) {
      if ((await _accessFor(tag, sector, card.uid)).state ==
          MifareSectorState.appOwned) {
        return true;
      }
    }
    return false;
  }

  @override
  Future<CardDiagnostic> diagnose(DetectedCard card) async {
    final tag = MifareClassicAndroid.from(card.handle as NfcTag)!;
    final details = <String>[];
    for (var sector = 1; sector < tag.sectorCount; sector++) {
      final access = await _accessFor(tag, sector, card.uid);
      details.add(
        'Sector $sector${sectors.contains(sector) ? ' · permitido' : ''}: ${switch (access.state) {
          MifareSectorState.free => 'libre',
          MifareSectorState.appOwned => 'de la app',
          MifareSectorState.occupied => 'ocupado/no accesible',
        }}',
      );
    }
    return CardDiagnostic(
      driverId: id,
      capacity: capacityBytes(card),
      details: details,
      hasPayload: await readPayload(card) != null,
    );
  }

  static void _validateTrailer(Uint8List trailer) {
    if (trailer.length != 16 ||
        !NdefDriver._bytesEqual(trailer.sublist(6, 10), _access)) {
      throw const AppException(
        'Bits de acceso MIFARE no válidos; escritura cancelada.',
      );
    }
  }
}

class _SectorAccess {
  const _SectorAccess(this.state, this.keyId);
  final MifareSectorState state;
  final int? keyId;
}
