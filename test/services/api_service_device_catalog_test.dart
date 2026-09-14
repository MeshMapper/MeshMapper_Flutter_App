import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/services/api_service.dart';
import 'package:mesh_mapper/models/device_catalog.dart';

Map<String, dynamic> catalogResponse() => {
      'success': true,
      'revision': 1,
      'devices': [
        {
          'id': 1,
          'manufacturer': 'Tracker',
          'shortName': 'Tracker',
          'aliases': <String>[],
          'power': 0.3,
          'platform': 'nrf52',
          'txPower': 22,
          'notes': '',
        }
      ],
    };

void main() {
  Map<String, dynamic> contractFixture() => jsonDecode(
        File('test/fixtures/device_catalog_contract.json').readAsStringSync(),
      ) as Map<String, dynamic>;

  test('executes catalog list and report envelopes from the shared fixture',
      () async {
    final fixture = contractFixture();
    var report = false;
    final api = ApiService(
      client: MockClient((_) async => http.Response(
            jsonEncode(report ? fixture['report'] : fixture['list']),
            200,
          )),
    );

    expect((await api.fetchDeviceCatalog())?.revision, 4);
    report = true;
    expect(
      await api.reportUnknownDevice(manufacturer: 'Unknown', appVersion: 'APP'),
      DeviceReportAcknowledgement.pending,
    );
  });

  test('fetches and strictly decodes the device catalog without callbacks',
      () async {
    late http.Request request;
    final api = ApiService(
      client: MockClient((incoming) async {
        request = incoming;
        return http.Response(jsonEncode(catalogResponse()), 200);
      }),
    );
    var callbacks = 0;
    api.onMaintenanceMode = (_, __) => callbacks++;
    api.onSessionError = (_, __, {subReason}) async => callbacks++;

    final catalog = await api.fetchDeviceCatalog();

    expect(request.url.path, '/wardrive-api.php/devices');
    expect(
        jsonDecode(request.body), {'key': ApiService.apiKey, 'action': 'list'});
    expect(catalog?.revision, 1);
    expect(callbacks, 0);
  });

  test('rejects non-200 and malformed catalog envelopes', () async {
    final rejected = ApiService(
      client: MockClient((_) async => http.Response('{"success":true}', 500)),
    );
    expect(await rejected.fetchDeviceCatalog(), isNull);

    final malformed = ApiService(
      client: MockClient((_) async => http.Response('{"success":"true"}', 200)),
    );
    expect(await malformed.fetchDeviceCatalog(), isNull);
  });

  test('acknowledges only an exact successful unknown report envelope',
      () async {
    late Map<String, dynamic> body;
    final api = ApiService(
      client: MockClient((request) async {
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('{"success":true,"status":"pending"}', 200);
      }),
    );
    final acknowledgement = await api.reportUnknownDevice(
      manufacturer: 'T1000e',
      appVersion: 'APP-TEST',
      firmwareVersion: '1.10.0',
    );
    expect(body, {
      'key': ApiService.apiKey,
      'action': 'report_unknown',
      'manufacturer': 'T1000e',
      'app_version': 'APP-TEST',
      'firmware_version': '1.10.0',
    });
    expect(acknowledgement, DeviceReportAcknowledgement.pending);
  });

  for (final status in <String>['known', 'pending', 'dismissed']) {
    test('accepts the $status report acknowledgement', () async {
      final api = ApiService(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({'success': true, 'status': status}),
            200,
          ),
        ),
      );
      expect(
        await api.reportUnknownDevice(
            manufacturer: 'Unknown', appVersion: 'APP'),
        DeviceReportAcknowledgement.values.byName(status),
      );
    });
  }

  test('rejects malformed UTF-8 from both catalog operations', () async {
    final api = ApiService(
      client: MockClient(
        (_) async => http.Response.bytes(<int>[0xc3, 0x28], 200),
      ),
    );
    expect(await api.fetchDeviceCatalog(), isNull);
    expect(
      await api.reportUnknownDevice(manufacturer: 'Unknown', appVersion: 'APP'),
      isNull,
    );
  });

  test('rejects report envelopes with unknown status or extra fields',
      () async {
    final api = ApiService(
      client: MockClient(
        (_) async => http.Response(
          '{"success":true,"status":"pending","extra":true}',
          200,
        ),
      ),
    );
    expect(
      await api.reportUnknownDevice(manufacturer: 'Unknown', appVersion: 'APP'),
      isNull,
    );
  });

  test('rejects every non-acknowledgement report envelope', () async {
    final responses = <String>[
      '{"success":true}',
      '{"success":true,"status":"unknown"}',
      '{"success":false,"status":"pending"}',
      '{"success":"true","status":"pending"}',
      '{"success":{},"status":"pending"}',
      '{"success":true,"status":123}',
      '{"success":true,"status":{}}',
      '{"success":true,"status":null}',
      '[]',
      '{bad json',
    ];
    for (final body in responses) {
      final api = ApiService(
        client: MockClient((_) async => http.Response(body, 200)),
      );
      expect(
        await api.reportUnknownDevice(
          manufacturer: 'Unknown',
          appVersion: 'APP',
        ),
        isNull,
        reason: body,
      );
    }
  });

  test('rejects a success-looking report response with non-200 status',
      () async {
    final api = ApiService(
      client: MockClient((_) async => http.Response(
            '{"success":true,"status":"pending"}',
            503,
          )),
    );
    expect(
      await api.reportUnknownDevice(manufacturer: 'Unknown', appVersion: 'APP'),
      isNull,
    );
  });

  test('rejects an oversized report response', () async {
    final body = utf8.encode(
      jsonEncode({'success': true, 'status': 'pending'}) +
          ('x' * (DeviceCatalog.maxEncodedBytes + 1)),
    );
    final api = ApiService(
      client: MockClient((_) async => http.Response.bytes(body, 200)),
    );
    expect(
      await api.reportUnknownDevice(manufacturer: 'Unknown', appVersion: 'APP'),
      isNull,
    );
  });

  for (final endpoint in <String>['list', 'report']) {
    for (final failure in <String>['success', 'failure']) {
      test('$endpoint does not invoke session callbacks on $failure', () async {
        var maintenance = 0;
        var expiring = 0;
        var sessionError = 0;
        var recovery = 0;
        final api = ApiService(
          client: MockClient((_) async {
            if (failure == 'success') {
              return http.Response(
                endpoint == 'list'
                    ? jsonEncode(catalogResponse())
                    : '{"success":true,"status":"known"}',
                200,
              );
            }
            return http.Response(
              '{"maintenance":true,"reason":"session_expired",'
              '"success":false}',
              503,
            );
          }),
        );
        api.onMaintenanceMode = (_, __) => maintenance++;
        api.onSessionExpiring = () => expiring++;
        api.onSessionError = (_, __, {subReason}) async => sessionError++;
        api.onSessionExpiredRecovery = () async {
          recovery++;
          return SessionRecoveryResult.failed;
        };

        if (endpoint == 'list') {
          await api.fetchDeviceCatalog();
        } else {
          await api.reportUnknownDevice(
            manufacturer: 'Unknown',
            appVersion: 'APP',
          );
        }

        expect(maintenance, 0);
        expect(expiring, 0);
        expect(sessionError, 0);
        expect(recovery, 0);
      });
    }
  }

  test('does not replay a catalog request after its deadline', () async {
    var now = DateTime.utc(2026, 1, 1);
    var calls = 0;
    final api = ApiService(
      deviceCatalogTimeout: const Duration(seconds: 1),
      now: () => now,
      client: MockClient((_) async {
        calls++;
        now = now.add(const Duration(seconds: 1));
        throw http.ClientException(
          'Connection closed before full header was received',
        );
      }),
    );

    expect(await api.fetchDeviceCatalog(), isNull);
    expect(calls, 1);
  });

  test('replays a catalog request before its deadline', () async {
    var now = DateTime.utc(2026, 1, 1);
    var calls = 0;
    final api = ApiService(
      deviceCatalogTimeout: const Duration(seconds: 1),
      now: () => now,
      client: MockClient((_) async {
        calls++;
        if (calls == 1) {
          now = now.add(const Duration(milliseconds: 999));
          throw http.ClientException(
            'Connection closed before full header was received',
          );
        }
        return http.Response(jsonEncode(catalogResponse()), 200);
      }),
    );

    expect((await api.fetchDeviceCatalog())?.revision, 1);
    expect(calls, 2);
  });

  for (final endpoint in <String>['list', 'report']) {
    Future<Object?> run(ApiService api) => endpoint == 'list'
        ? api.fetchDeviceCatalog()
        : api.reportUnknownDevice(manufacturer: 'Unknown', appVersion: 'APP');

    test('$endpoint replays after a stale failure just before its deadline',
        () async {
      var now = DateTime.utc(2026, 1, 1);
      var calls = 0;
      final api = ApiService(
        deviceCatalogTimeout: const Duration(seconds: 1),
        now: () => now,
        client: MockClient((_) async {
          calls++;
          if (calls == 1) {
            now = now.add(const Duration(milliseconds: 999));
            throw http.ClientException(
              'Connection closed before full header was received',
            );
          }
          return endpoint == 'list'
              ? http.Response(jsonEncode(catalogResponse()), 200)
              : http.Response('{"success":true,"status":"pending"}', 200);
        }),
      );
      expect(await run(api), isNotNull);
      expect(calls, 2);
    });

    test('$endpoint never replays when stale failure completes at its deadline',
        () async {
      var now = DateTime.utc(2026, 1, 1);
      var calls = 0;
      final api = ApiService(
        deviceCatalogTimeout: const Duration(seconds: 1),
        now: () => now,
        client: MockClient((_) async {
          calls++;
          now = now.add(const Duration(seconds: 1));
          throw http.ClientException(
            'Connection closed before full header was received',
          );
        }),
      );
      expect(await run(api), isNull);
      expect(calls, 1);
    });

    test('$endpoint never replays when stale failure completes after deadline',
        () async {
      var now = DateTime.utc(2026, 1, 1);
      var calls = 0;
      final api = ApiService(
        deviceCatalogTimeout: const Duration(seconds: 1),
        now: () => now,
        client: MockClient((_) async {
          calls++;
          now = now.add(const Duration(milliseconds: 1001));
          throw http.ClientException(
            'Connection closed before full header was received',
          );
        }),
      );
      expect(await run(api), isNull);
      expect(calls, 1);
    });

    test('$endpoint gives a replay only its remaining deadline budget',
        () async {
      var now = DateTime.utc(2026, 1, 1);
      var calls = 0;
      final api = ApiService(
        deviceCatalogTimeout: const Duration(seconds: 1),
        now: () => now,
        client: MockClient((_) async {
          calls++;
          if (calls == 1) {
            now = now.add(const Duration(milliseconds: 700));
            throw http.ClientException(
              'Connection closed before full header was received',
            );
          }
          return Future<http.Response>.delayed(
            const Duration(milliseconds: 400),
            () => endpoint == 'list'
                ? http.Response(jsonEncode(catalogResponse()), 200)
                : http.Response('{"success":true,"status":"pending"}', 200),
          );
        }),
      );
      expect(await run(api), isNull);
      expect(calls, 2);
    });

    test('$endpoint rejects a response completing after its absolute deadline',
        () async {
      var now = DateTime.utc(2026, 1, 1);
      final api = ApiService(
        deviceCatalogTimeout: const Duration(seconds: 1),
        now: () => now,
        client: MockClient((_) async {
          now = now.add(const Duration(seconds: 1));
          return endpoint == 'list'
              ? http.Response(jsonEncode(catalogResponse()), 200)
              : http.Response('{"success":true,"status":"pending"}', 200);
        }),
      );
      expect(await run(api), isNull);
    });
  }

  for (final report in [false, true]) {
    test('${report ? 'report' : 'list'} honors its outer timeout', () async {
      final stuck = Completer<http.Response>();
      final api = ApiService(
        deviceCatalogTimeout: const Duration(milliseconds: 10),
        client: MockClient((_) => stuck.future),
      );

      final result = report
          ? await api.reportUnknownDevice(
              manufacturer: 'Unknown', appVersion: 'APP')
          : await api.fetchDeviceCatalog();
      expect(result, isNull);
    });
  }
}
