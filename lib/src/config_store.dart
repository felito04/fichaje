import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';

class ConfigStore {
  ConfigStore(this._preferences);
  static Future<ConfigStore> create() async =>
      ConfigStore(await SharedPreferences.getInstance());
  final SharedPreferences _preferences;

  AppConfig load() => AppConfig(
    baseUrl: _preferences.getString('base_url') ?? AppConfig.productionUrl,
    tabletId: _preferences.getString('tablet_id') ?? 'tablet-oficina-1',
    mifareSectors:
        (_preferences.getStringList('mifare_sectors') ??
                const ['13', '14', '15'])
            .map(int.parse)
            .toList(),
    latitude: _preferences.getDouble('latitude'),
    longitude: _preferences.getDouble('longitude'),
  );

  Future<void> save(AppConfig value) async {
    await _preferences.setString(
      'base_url',
      value.baseUrl.replaceAll(RegExp(r'/+$'), ''),
    );
    await _preferences.setString('tablet_id', value.tabletId);
    await _preferences.setStringList(
      'mifare_sectors',
      value.mifareSectors.map((e) => '$e').toList(),
    );
    if (value.hasLocation) {
      await _preferences.setDouble('latitude', value.latitude!);
      await _preferences.setDouble('longitude', value.longitude!);
    } else {
      await _preferences.remove('latitude');
      await _preferences.remove('longitude');
    }
  }
}
