import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/services/api_service.dart';

void main() {
  ApiService serviceAnswering(http.Response Function(http.Request) responder) =>
      ApiService(client: MockClient((request) async => responder(request)));

  group('fetchRepeaterCoverage separates "nothing" from "could not ask"', () {
    test('points come back as points', () async {
      final api = serviceAnswering((_) => http.Response(
            json.encode([
              {'status': 1, 'lat': 45.0, 'lon': -75.0},
            ]),
            200,
          ));

      final points = await api.fetchRepeaterCoverage(zone: 'yow', prefix: 'ab');

      expect(points, isNotNull);
      expect(points!.length, 1);
    });

    test('an empty list is a real answer, not a failure', () async {
      final api = serviceAnswering((_) => http.Response('[]', 200));

      final points = await api.fetchRepeaterCoverage(zone: 'yow', prefix: 'ab');

      expect(points, isNotNull, reason: 'the server answered: it has nothing');
      expect(points, isEmpty);
    });

    test('an HTTP error is "could not ask"', () async {
      final api = serviceAnswering((_) => http.Response('nope', 500));

      expect(
          await api.fetchRepeaterCoverage(zone: 'yow', prefix: 'ab'), isNull);
    });

    test('a body that is not a JSON list is "could not ask"', () async {
      final api =
          serviceAnswering((_) => http.Response('{"error":"boom"}', 200));

      expect(
          await api.fetchRepeaterCoverage(zone: 'yow', prefix: 'ab'), isNull);
    });

    test('a transport failure is "could not ask"', () async {
      final api = ApiService(
          client: MockClient((_) async => throw http.ClientException('down')));

      expect(
          await api.fetchRepeaterCoverage(zone: 'yow', prefix: 'ab'), isNull);
    });
  });

  group('fetchMapData still collapses failure to empty', () {
    // The cell summary has no "couldn't load" state (#109 is the repeater
    // sheet only), and its tap flow chains straight into filterWithinBlob.
    test('an HTTP error yields an empty list, never null', () async {
      final api = serviceAnswering((_) => http.Response('nope', 500));

      final points = await api.fetchMapData(
          zone: 'yow', lat: 45.0, lon: -75.0, radiusMeters: 300);

      expect(points, isEmpty);
    });

    test('points still come back as points', () async {
      final api = serviceAnswering((_) => http.Response(
            json.encode([
              {'status': 1, 'lat': 45.0, 'lon': -75.0},
            ]),
            200,
          ));

      final points = await api.fetchMapData(
          zone: 'yow', lat: 45.0, lon: -75.0, radiusMeters: 300);

      expect(points.length, 1);
    });
  });
}
