import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/services/api_service.dart';

/// Every read of region data carries the radio preset filter (f_freq, f_bw,
/// f_sf, never f_cr) when the radio reported its parameters, and nothing at
/// all otherwise. One getter feeds all four readers so none of their
/// signatures change.
void main() {
  const filter = {'f_freq': '910.525', 'f_bw': '62.5', 'f_sf': '7'};

  http.Request? seen;
  ApiService api({Map<String, String>? answer, bool wired = true}) {
    final svc = ApiService(client: MockClient((request) async {
      seen = request;
      if (request.url.path.endsWith('/get_repeaters.php')) {
        return http.Response('[]', 200);
      }
      if (request.url.path.endsWith('/app_coverage.php')) {
        return http.Response('[]', 200);
      }
      return http.Response('', 204);
    }));
    if (wired) svc.radioFilterGetter = () => answer;
    return svc;
  }

  setUp(() => seen = null);

  group('overlay fresh refetch', () {
    test('carries the three slots and never f_cr', () async {
      await api(answer: filter)
          .freshenVectorTile(zone: 'yow', z: 14, x: 1, y: 2, gsize: 300);
      final q = seen!.url.queryParameters;
      expect(q['fresh'], '1');
      expect(q['f_freq'], '910.525');
      expect(q['f_bw'], '62.5');
      expect(q['f_sf'], '7');
      expect(q.containsKey('f_cr'), isFalse);
    });

    test('sends no filter when the getter answers null', () async {
      await api(answer: null)
          .freshenVectorTile(zone: 'yow', z: 14, x: 1, y: 2, gsize: 300);
      final q = seen!.url.queryParameters;
      expect(q.keys.where((k) => k.startsWith('f_')), isEmpty);
    });

    test('sends no filter when nothing is wired', () async {
      await api(wired: false)
          .freshenVectorTile(zone: 'yow', z: 14, x: 1, y: 2, gsize: 300);
      expect(seen!.url.queryParameters.keys.where((k) => k.startsWith('f_')),
          isEmpty);
    });
  });

  test('smart pinging tile keeps its own filters and adds the preset',
      () async {
    await api(answer: filter)
        .fetchRecentCoverageTile(zone: 'yow', x: 1, y: 2, gsize: 300, days: 14);
    final q = seen!.url.queryParameters;
    expect(q['f_days'], '14');
    expect(q['f_types'], 'green,cyan');
    expect(q['f_freq'], '910.525');
    expect(q['f_bw'], '62.5');
    expect(q['f_sf'], '7');
    expect(q.containsKey('f_cr'), isFalse);
  });

  group('coverage taps', () {
    test('map_data carries the slots in the JSON body', () async {
      await api(answer: filter)
          .fetchMapData(zone: 'yow', lat: 45.0, lon: -75.0, radiusMeters: 50);
      final body = json.decode(seen!.body) as Map<String, dynamic>;
      expect(body['request'], 'map_data');
      expect(body['f_freq'], '910.525');
      expect(body['f_bw'], '62.5');
      expect(body['f_sf'], '7');
      expect(body.containsKey('f_cr'), isFalse);
    });

    test('repeater_coverage carries the slots in the JSON body', () async {
      await api(answer: filter)
          .fetchRepeaterCoverage(zone: 'yow', prefix: 'ab');
      final body = json.decode(seen!.body) as Map<String, dynamic>;
      expect(body['request'], 'repeater_coverage');
      expect(body['f_sf'], '7');
    });

    test('no filter means no f_ keys in the body', () async {
      await api(answer: null).fetchRepeaterCoverage(zone: 'yow', prefix: 'ab');
      final body = json.decode(seen!.body) as Map<String, dynamic>;
      expect(body.keys.where((k) => k.startsWith('f_')), isEmpty);
    });
  });

  group('repeater list', () {
    test('carries the slots as a query string', () async {
      await api(answer: filter).fetchRepeaters('yow');
      expect(seen!.url.host, 'yow.meshmapper.net');
      expect(seen!.url.path, '/get_repeaters.php');
      final q = seen!.url.queryParameters;
      expect(q['f_freq'], '910.525');
      expect(q['f_bw'], '62.5');
      expect(q['f_sf'], '7');
    });

    test('no filter leaves the URL exactly as before', () async {
      await api(answer: null).fetchRepeaters('yow');
      expect(
          seen!.url.toString(), 'https://yow.meshmapper.net/get_repeaters.php');
    });
  });
}
