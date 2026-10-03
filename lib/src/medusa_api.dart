import 'package:dio/dio.dart';
import 'models.dart';

class MedusaSession {
  const MedusaSession({required this.token, required this.email});
  final String token;
  final String email;
}

class MedusaApi {
  MedusaApi({required String baseUrl, Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: baseUrl,
              connectTimeout: _timeout,
              receiveTimeout: _timeout,
              sendTimeout: _timeout,
            ),
          );
  static const _timeout = Duration(seconds: 10);
  final Dio _dio;

  Future<MedusaSession> login(String email, String password) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/auth/user/emailpass',
        data: {'email': email, 'password': password},
      );
      final token = response.data?['token'] as String?;
      if (token == null || token.isEmpty) {
        throw const AppException('Respuesta de inicio de sesión no válida.');
      }
      return MedusaSession(token: token, email: email);
    } on DioException catch (error) {
      if (error.response?.statusCode == 401) {
        throw const AppException(
          'Email o contraseña incorrectos.',
          kind: AppErrorKind.invalidCredentials,
        );
      }
      throw _mapError(error);
    }
  }

  Future<TodayState> today(MedusaSession session) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/admin/time-entry/today',
        options: _auth(session),
      );
      return TodayState.fromJson(response.data ?? const {}, session.email);
    } on DioException catch (error) {
      throw _mapError(error);
    }
  }

  Future<DateTime> perform(
    MedusaSession session,
    PunchAction action, {
    required String idempotencyKey,
    required AppConfig config,
  }) async {
    final path = switch (action) {
      PunchAction.clockIn => '/admin/time-entry/clock-in',
      PunchAction.clockOut => '/admin/time-entry/clock-out',
      PunchAction.pauseMeal ||
      PunchAction.pauseBreak => '/admin/time-entry/pause-start',
      PunchAction.pauseEnd => '/admin/time-entry/pause-end',
    };
    final data = <String, dynamic>{
      'notes': 'Quiosco NFC - ${config.tabletId}',
      'idempotency_key': idempotencyKey,
    };
    if (action == PunchAction.pauseMeal) data['activity_type'] = 'COMIDA';
    if (action == PunchAction.pauseBreak) data['activity_type'] = 'DESCANSO';
    if (action == PunchAction.clockIn || action == PunchAction.clockOut) {
      if (config.hasLocation) {
        data['geolocation'] = {'lat': config.latitude, 'lng': config.longitude};
        data['geolocation_context'] = {'status': 'WITH_GPS'};
      } else {
        data['geolocation_context'] = {
          'status': 'WITHOUT_GPS_UNSUPPORTED',
          'message': 'Quiosco NFC',
        };
      }
    }

    DioException? lastNetworkError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final response = await _dio.post<Map<String, dynamic>>(
          path,
          data: data,
          options: _auth(session),
        );
        final entry = response.data?['entry'] as Map<String, dynamic>?;
        return DateTime.parse(entry?['clock_time'] as String);
      } on DioException catch (error) {
        if (!_isNetworkFailure(error)) throw _mapError(error);
        lastNetworkError = error;
      }
    }
    throw _mapError(lastNetworkError!);
  }

  Future<void> testConnection() async {
    try {
      await _dio.get<void>(
        '/health',
        options: Options(
          validateStatus: (status) => status != null && status < 500,
        ),
      );
    } on DioException catch (error) {
      throw _mapError(error);
    }
  }

  Options _auth(MedusaSession session) =>
      Options(headers: {'Authorization': 'Bearer ${session.token}'});
  bool _isNetworkFailure(DioException error) => const {
    DioExceptionType.connectionTimeout,
    DioExceptionType.sendTimeout,
    DioExceptionType.receiveTimeout,
    DioExceptionType.connectionError,
    DioExceptionType.unknown,
  }.contains(error.type);

  AppException _mapError(DioException error) {
    if (_isNetworkFailure(error)) {
      return const AppException(
        'Sin conexión, inténtalo de nuevo.',
        kind: AppErrorKind.network,
      );
    }
    final data = error.response?.data;
    final message = data is Map<String, dynamic>
        ? data['message'] as String?
        : null;
    return AppException(
      message ??
          'No se pudo completar la operación (${error.response?.statusCode ?? 'error'}).',
    );
  }
}
