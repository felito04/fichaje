import 'dart:typed_data';

import 'package:fichaje/src/models.dart';
import 'package:fichaje/src/security.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('credential envelope round-trips and contains no plaintext', () async {
    const storage = FlutterSecureStorage();
    final vault = KeyVault(storage);
    await vault.ensureKey();
    final codec = CredentialCodec(vault);
    final uid = Uint8List.fromList([1, 2, 3, 4]);
    const credentials = CardCredentials(
      email: 'empleado@example.com',
      password: 'secreto',
      userId: 'user_123',
    );

    final envelope = await codec.encode(credentials, uid);
    final decoded = await codec.decode(envelope, uid);

    expect(decoded.email, credentials.email);
    expect(decoded.password, credentials.password);
    expect(decoded.userId, credentials.userId);
    expect(String.fromCharCodes(envelope), isNot(contains(credentials.email)));
    expect(envelope.sublist(0, 4), [0x4d, 0x55, 0x53, 0x46]);
  });

  test('credential envelope cannot be copied to a different UID', () async {
    const storage = FlutterSecureStorage();
    final vault = KeyVault(storage);
    await vault.ensureKey();
    final codec = CredentialCodec(vault);
    final envelope = await codec.encode(
      const CardCredentials(
        email: 'a@b.com',
        password: 'secret',
        userId: 'user_1',
      ),
      Uint8List.fromList([1, 2, 3, 4]),
    );

    expect(
      () => codec.decode(envelope, Uint8List.fromList([4, 3, 2, 1])),
      throwsA(isA<AppException>()),
    );
  });
}
