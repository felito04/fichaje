import 'dart:typed_data';

enum EntryType {
  clockIn('ENTRADA'),
  clockOut('SALIDA'),
  pauseStart('PAUSA_INICIO'),
  pauseEnd('PAUSA_FIN');

  const EntryType(this.wireValue);
  final String wireValue;

  static EntryType fromWire(String value) =>
      values.firstWhere((type) => type.wireValue == value);
}

enum WorkStatus { notClockedIn, working, paused }

enum PunchAction { clockIn, clockOut, pauseMeal, pauseBreak, pauseEnd }

class TimeEntry {
  const TimeEntry({required this.id, required this.type, required this.time});
  factory TimeEntry.fromJson(Map<String, dynamic> json) => TimeEntry(
    id: json['id'] as String,
    type: EntryType.fromWire(json['entry_type'] as String),
    time: DateTime.parse(json['clock_time'] as String),
  );
  final String id;
  final EntryType type;
  final DateTime time;
}

class TodayState {
  const TodayState({
    required this.entries,
    required this.userId,
    required this.displayName,
  });

  factory TodayState.fromJson(Map<String, dynamic> json, String fallbackName) {
    final user = json['user'] as Map<String, dynamic>?;
    return TodayState(
      entries:
          (json['entries'] as List<dynamic>? ?? const [])
              .map((item) => TimeEntry.fromJson(item as Map<String, dynamic>))
              .toList()
            ..sort((a, b) => a.time.compareTo(b.time)),
      userId: user?['id'] as String?,
      displayName: (user?['display_name'] as String?)?.trim().isNotEmpty == true
          ? user!['display_name'] as String
          : fallbackName,
    );
  }

  final List<TimeEntry> entries;
  final String? userId;
  final String displayName;
  TimeEntry? get last => entries.isEmpty ? null : entries.last;

  WorkStatus get status => switch (last?.type) {
    null || EntryType.clockOut => WorkStatus.notClockedIn,
    EntryType.clockIn || EntryType.pauseEnd => WorkStatus.working,
    EntryType.pauseStart => WorkStatus.paused,
  };

  PunchAction get suggestedAction => switch (status) {
    WorkStatus.notClockedIn => PunchAction.clockIn,
    WorkStatus.working => PunchAction.clockOut,
    WorkStatus.paused => PunchAction.pauseEnd,
  };

  Duration get workedDuration {
    Duration total = Duration.zero;
    DateTime? runningFrom;
    for (final entry in entries) {
      switch (entry.type) {
        case EntryType.clockIn:
        case EntryType.pauseEnd:
          runningFrom = entry.time;
        case EntryType.clockOut:
        case EntryType.pauseStart:
          if (runningFrom != null && entry.time.isAfter(runningFrom)) {
            total += entry.time.difference(runningFrom);
          }
          runningFrom = null;
      }
    }
    if (runningFrom != null) {
      total += DateTime.now().toUtc().difference(runningFrom);
    }
    return total;
  }
}

class CardCredentials {
  const CardCredentials({
    required this.email,
    required this.password,
    required this.userId,
  });
  final String email;
  final String password;
  final String userId;
}

class DetectedCard {
  const DetectedCard({
    required this.uid,
    required this.technologies,
    required this.handle,
  });
  final Uint8List uid;
  final Set<String> technologies;
  final Object handle;
  String get uidHex => uid
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join(':')
      .toUpperCase();
}

class AppConfig {
  const AppConfig({
    required this.baseUrl,
    required this.tabletId,
    required this.mifareSectors,
    this.latitude,
    this.longitude,
  });
  static const productionUrl = 'https://talleres.myurbanscoot.com';
  final String baseUrl;
  final String tabletId;
  final List<int> mifareSectors;
  final double? latitude;
  final double? longitude;
  bool get hasLocation => latitude != null && longitude != null;

  AppConfig copyWith({
    String? baseUrl,
    String? tabletId,
    List<int>? mifareSectors,
    double? latitude,
    double? longitude,
    bool clearLocation = false,
  }) => AppConfig(
    baseUrl: baseUrl ?? this.baseUrl,
    tabletId: tabletId ?? this.tabletId,
    mifareSectors: mifareSectors ?? this.mifareSectors,
    latitude: clearLocation ? null : latitude ?? this.latitude,
    longitude: clearLocation ? null : longitude ?? this.longitude,
  );
}

class AppException implements Exception {
  const AppException(this.message, {this.kind = AppErrorKind.other});
  final String message;
  final AppErrorKind kind;
  @override
  String toString() => message;
}

enum AppErrorKind { invalidCredentials, network, invalidCard, capacity, other }
