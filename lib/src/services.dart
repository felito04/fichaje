import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

import 'config_store.dart';
import 'medusa_api.dart';
import 'models.dart';
import 'nfc.dart';
import 'security.dart';

class AppServices {
  AppServices._({
    required this.configStore,
    required this.keyVault,
    required this.pinStore,
    required this.biometricAuth,
    required this.reader,
    required this.codec,
    required AppConfig config,
  }) : _config = config;

  static Future<AppServices> create() async {
    const secureStorage = FlutterSecureStorage(aOptions: AndroidOptions());
    final configStore = await ConfigStore.create();
    final keyVault = KeyVault(secureStorage);
    await keyVault.ensureKey();
    return AppServices._(
      configStore: configStore,
      keyVault: keyVault,
      pinStore: AdminPinStore(secureStorage),
      biometricAuth: BiometricAdminAuth(),
      reader: InternalAndroidReader(),
      codec: CredentialCodec(keyVault),
      config: configStore.load(),
    );
  }

  final ConfigStore configStore;
  final KeyVault keyVault;
  final AdminPinStore pinStore;
  final BiometricAdminAuth biometricAuth;
  final NfcReader reader;
  final CredentialCodec codec;
  AppConfig _config;

  AppConfig get config => _config;
  MedusaApi get api => MedusaApi(baseUrl: _config.baseUrl);
  CardDriverRegistry get registry => CardDriverRegistry([
    MifareClassicDriver(vault: keyVault, sectors: _config.mifareSectors),
    NdefDriver(vault: keyVault),
  ]);

  Future<void> updateConfig(AppConfig value) async {
    await configStore.save(value);
    _config = configStore.load();
  }
}

class BiometricAdminAuth {
  BiometricAdminAuth({LocalAuthentication? authentication})
    : _authentication = authentication ?? LocalAuthentication();

  final LocalAuthentication _authentication;

  Future<bool> get isAvailable async {
    try {
      if (!await _authentication.isDeviceSupported()) return false;
      return (await _authentication.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<bool> authenticate() => _authentication.authenticate(
    localizedReason: 'Identifícate para abrir el modo administración',
    biometricOnly: true,
    persistAcrossBackgrounding: true,
  );
}

class KioskPlatform {
  static const _channel = MethodChannel('com.myurbanscoot.fichaje/kiosk');
  static Future<void> start() async {
    try {
      await _channel.invokeMethod<void>('startLockTask');
    } on PlatformException {
      // Screen pinning may be declined or unavailable outside device-owner mode.
    } on MissingPluginException {
      // Allows development on non-Android platforms.
    }
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stopLockTask');
    } on PlatformException {
      // stopLockTask throws when pinning was not active; admin mode may still open.
    } on MissingPluginException {
      // Allows development on non-Android platforms.
    }
  }
}
