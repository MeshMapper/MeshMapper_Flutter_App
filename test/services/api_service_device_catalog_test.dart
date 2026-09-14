import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/services/api_service.dart';

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
