import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'models.dart';

class KeyVault {
  KeyVault(this._storage);
  final FlutterSecureStorage _storage;
  static const _currentIdName = 'musf_current_key_id';
  static const _keyIdsName = 'musf_key_ids';

  Future<int> ensureKey() async {
    final stored = await _storage.read(key: _currentIdName);
    if (stored != null) return int.parse(stored);
    await _storage.write(
      key: _keyName(1),
      value: base64Encode(_randomBytes(32)),
    );
    await _storage.write(key: _currentIdName, value: '1');
    await _storage.write(key: _keyIdsName, value: '1');
    return 1;
  }

  Future<int> get currentKeyId => ensureKey();

  Future<SecretKey> key(int id) async {
    final encoded = await _storage.read(key: _keyName(id));
    if (encoded == null) {
      throw const AppException(
        'La tarjeta usa una clave que no está instalada.',
        kind: AppErrorKind.invalidCard,
      );
    }
    final bytes = base64Decode(encoded);
    if (bytes.length != 32) {
      throw const AppException('La clave instalada no es válida.');
    }
    return SecretKey(bytes);
  }

  Future<List<int>> installedKeyIds() async {
    final indexed = await _storage.read(key: _keyIdsName);
    if (indexed != null && indexed.isNotEmpty) {
      return indexed.split(',').map(int.parse).toList();
    }
    final result = <int>[];
    for (var id = 1; id <= 255; id++) {
      if (await _storage.containsKey(key: _keyName(id))) {
        result.add(id);
      }
    }
    await _storage.write(key: _keyIdsName, value: result.join(','));
    return result;
  }

  Future<int> rotate() async {
    final current = await ensureKey();
    final next = current == 255 ? 1 : current + 1;
    await _storage.write(
      key: _keyName(next),
      value: base64Encode(_randomBytes(32)),
    );
    await _storage.write(key: _currentIdName, value: '$next');
    final ids = {...await installedKeyIds(), next}.toList()..sort();
    await _storage.write(key: _keyIdsName, value: ids.join(','));
    return next;
  }

  Future<String> exportBundle() async {
    final current = await ensureKey();
    final keys = <String, String>{};
    for (final id in await installedKeyIds()) {
      final value = await _storage.read(key: _keyName(id));
      if (value != null) keys['$id'] = value;
    }
    return 'MUSFKEY1:${base64UrlEncode(utf8.encode(jsonEncode({'current': current, 'keys': keys})))}';
  }

  Future<void> importBundle(String value) async {
    if (!value.startsWith('MUSFKEY1:')) {
      throw const AppException(
        'El QR no contiene una clave de fichaje válida.',
      );
    }
    try {
      final decoded =
          jsonDecode(utf8.decode(base64Url.decode(value.substring(9))))
              as Map<String, dynamic>;
      final current = decoded['current'] as int;
      final keys = (decoded['keys'] as Map<String, dynamic>)
          .cast<String, String>();
      if (!keys.containsKey('$current') ||
          keys.values.any((item) => base64Decode(item).length != 32)) {
        throw const FormatException();
      }
      for (final entry in keys.entries) {
        await _storage.write(
          key: _keyName(int.parse(entry.key)),
          value: entry.value,
        );
      }
      await _storage.write(key: _currentIdName, value: '$current');
      final ids = {
        ...await installedKeyIds(),
        ...keys.keys.map(int.parse),
      }.toList()..sort();
      await _storage.write(key: _keyIdsName, value: ids.join(','));
    } catch (_) {
      throw const AppException(
        'El QR no contiene una clave de fichaje válida.',
      );
    }
  }

  Future<Uint8List> deriveMifareKey(
    Uint8List uid, {
    required bool keyA,
    int? keyId,
  }) async {
    final master = await key(keyId ?? await currentKeyId);
    final result = await Hkdf(hmac: Hmac.sha256(), outputLength: 6).deriveKey(
      secretKey: master,
      nonce: uid,
      info: utf8.encode(keyA ? 'MUSF-MIFARE-KEY-A' : 'MUSF-MIFARE-KEY-B'),
    );
    return Uint8List.fromList(await result.extractBytes());
  }

  Future<Uint8List> deriveNtagProtection(Uint8List uid, {int? keyId}) async {
    final master = await key(keyId ?? await currentKeyId);
    final result = await Hkdf(hmac: Hmac.sha256(), outputLength: 6).deriveKey(
      secretKey: master,
      nonce: uid,
      info: utf8.encode('MUSF-NTAG21X-PWD-PACK'),
    );
    return Uint8List.fromList(await result.extractBytes());
  }

  static String _keyName(int id) => 'musf_key_$id';
  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List.generate(length, (_) => random.nextInt(256)),
    );
  }
}

class CredentialCodec {
  CredentialCodec(this._vault);
  final KeyVault _vault;
  static final _magic = utf8.encode('MUSF');
  static const headerLength = 20;

  bool looksLikeEnvelope(Uint8List bytes) =>
      bytes.length >= headerLength &&
      _same(bytes.sublist(0, 4), _magic) &&
      bytes[4] == 1;

  Future<Uint8List> encode(CardCredentials credentials, Uint8List uid) async {
    final keyId = await _vault.currentKeyId;
    final clearText = utf8.encode(
      jsonEncode({
        'e': credentials.email,
        'p': credentials.password,
        'u': credentials.userId,
      }),
    );
    final nonce = KeyVault._randomBytes(12);
    final box = await AesGcm.with256bits().encrypt(
      clearText,
      secretKey: await _vault.key(keyId),
      nonce: nonce,
      aad: uid,
    );
    final encrypted = Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
    if (encrypted.length > 65535) {
      throw const AppException(
        'Las credenciales son demasiado largas para una tarjeta.',
      );
    }
    return Uint8List.fromList([
      ..._magic,
      1,
      keyId,
      encrypted.length >> 8,
      encrypted.length & 0xff,
      ...nonce,
      ...encrypted,
    ]);
  }

  Future<CardCredentials> decode(Uint8List envelope, Uint8List uid) async {
    try {
      if (!looksLikeEnvelope(envelope)) throw const FormatException();
      final encryptedLength = (envelope[6] << 8) | envelope[7];
      if (encryptedLength < 17 ||
          envelope.length < headerLength + encryptedLength) {
        throw const FormatException();
      }
      final encrypted = envelope.sublist(
        headerLength,
        headerLength + encryptedLength,
      );
      final clear = await AesGcm.with256bits().decrypt(
        SecretBox(
          encrypted.sublist(0, encrypted.length - 16),
          nonce: envelope.sublist(8, 20),
          mac: Mac(encrypted.sublist(encrypted.length - 16)),
        ),
        secretKey: await _vault.key(envelope[5]),
        aad: uid,
      );
      final json = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
      final email = json['e'] as String;
      final password = json['p'] as String;
      final userId = json['u'] as String;
      if (email.isEmpty || password.isEmpty || userId.isEmpty) {
        throw const FormatException();
      }
      return CardCredentials(email: email, password: password, userId: userId);
    } catch (error) {
      if (error is AppException) rethrow;
      throw const AppException(
        'No se pudo validar esta tarjeta. Puede haberse programado con otra clave o pertenecer a otra tablet.',
        kind: AppErrorKind.invalidCard,
      );
    }
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var result = 0;
    for (var i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }
}

class AdminPinStore {
  AdminPinStore(this._storage);
  final FlutterSecureStorage _storage;

  Future<bool> get isConfigured async =>
      await _storage.read(key: 'admin_pin_hash') != null;

  Future<void> setPin(String pin) async {
    if (!RegExp(r'^\d{4,8}$').hasMatch(pin)) {
      throw const AppException('El PIN debe tener entre 4 y 8 cifras.');
    }
    final salt = KeyVault._randomBytes(16);
    final hash = await Sha256().hash([...salt, ...utf8.encode(pin)]);
    await _storage.write(key: 'admin_pin_salt', value: base64Encode(salt));
    await _storage.write(
      key: 'admin_pin_hash',
      value: base64Encode(hash.bytes),
    );
  }

  Future<bool> verify(String pin) async {
    final saltText = await _storage.read(key: 'admin_pin_salt');
    final expectedText = await _storage.read(key: 'admin_pin_hash');
    if (saltText == null || expectedText == null) return false;
    final actual = await Sha256().hash([
      ...base64Decode(saltText),
      ...utf8.encode(pin),
    ]);
    return CredentialCodec._same(actual.bytes, base64Decode(expectedText));
  }
}
