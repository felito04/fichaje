import 'package:dio/dio.dart';
import 'package:fichaje/src/medusa_api.dart';
import 'package:fichaje/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const config = AppConfig(
    baseUrl: 'https://staging.example.com',
    tabletId: 'tablet-test',
    mifareSectors: [13, 14, 15],
  );
  const session = MedusaSession(token: 'token', email: 'user@example.com');

  test('network retry reuses the same idempotency key', () async {
    final dio = Dio(BaseOptions(baseUrl: config.baseUrl));
    final seenKeys = <String>[];
    var attempts = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          attempts++;
          seenKeys.add(
            (options.data as Map<String, dynamic>)['idempotency_key'] as String,
          );
          if (attempts == 1) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
              ),
            );
          } else {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 201,
                data: {
                  'entry': {'clock_time': '2026-10-03T07:02:11.000Z'},
                },
              ),
            );
          }
        },
      ),
    );

    final result = await MedusaApi(baseUrl: config.baseUrl, dio: dio).perform(
      session,
      PunchAction.clockIn,
      idempotencyKey: 'same-uuid',
      config: config,
    );

    expect(result, DateTime.parse('2026-10-03T07:02:11.000Z'));
    expect(seenKeys, ['same-uuid', 'same-uuid']);
  });

  test('backend business message is preserved and is not retried', () async {
    final dio = Dio(BaseOptions(baseUrl: config.baseUrl));
    var attempts = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          attempts++;
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.badResponse,
              response: Response(
                requestOptions: options,
                statusCode: 500,
                data: {
                  'message':
                      'No se puede fichar entrada. Ya existe una entrada sin salida.',
                },
              ),
            ),
          );
        },
      ),
    );

    await expectLater(
      MedusaApi(baseUrl: config.baseUrl, dio: dio).perform(
        session,
        PunchAction.clockIn,
        idempotencyKey: 'uuid',
        config: config,
      ),
      throwsA(
        isA<AppException>().having(
          (error) => error.message,
          'message',
          'No se puede fichar entrada. Ya existe una entrada sin salida.',
        ),
      ),
    );
    expect(attempts, 1);
  });
}
