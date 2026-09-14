import 'dart:convert';

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
}
