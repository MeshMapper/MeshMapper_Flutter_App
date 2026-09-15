import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/services/api_service.dart';

void main() {
  group('lower-zoom fresh tiles keep the verdict without downloading a body',
      () {
    for (final z in [11, 12, 13]) {
      test('z$z still forces a render with the same coverage filters',
          () async {
        final api = ApiService(client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.headers['if-none-match'], '*');
          expect(request.url.host, 'yow.meshmapper.net');
          expect(request.url.queryParameters, {
            'z': '$z',
            'x': '4173',
            'y': '6157',
            'gsize': '100',
            'fresh': '1',
            'f_freq': '910.525',
            'f_bw': '62.5',
            'f_sf': '7',
            'f_days': '30',
          });
          return http.Response('', 304, headers: {'x-tile-changed': '1'});
        }));
        api.radioFilterGetter =
            () => {'f_freq': '910.525', 'f_bw': '62.5', 'f_sf': '7'};

        final result = await api.freshenVectorTile(
            zone: 'YOW', z: z, x: 4173, y: 6157, gsize: 100, recentDays: 30);

        expect(result.changed, isTrue);
        expect(result.body, isNull);
      });
    }

    for (final verdict in ['1', '0', null]) {
      test('304 preserves $verdict for the existing retry decision', () async {
        final api = ApiService(client: MockClient((_) async {
          return http.Response('', 304,
              headers: {if (verdict != null) 'x-tile-changed': verdict});
        }));

        final result =
            await api.freshenVectorTile(zone: 'yow', z: 13, x: 1, y: 2);

        expect(result.changed, verdict == null ? null : verdict == '1');
        expect(result.body, isNull);
      });
    }

    test('a server ignoring the conditional header still works', () async {
      final api = ApiService(client: MockClient((_) async {
        return http.Response.bytes([1, 2, 3], 200,
            headers: {'x-tile-changed': '1'});
      }));

      final result =
          await api.freshenVectorTile(zone: 'yow', z: 11, x: 1, y: 2);

      expect(result.changed, isTrue);
      expect(result.body, [1, 2, 3]);
    });

    test('empty tiles retain the server verdict', () async {
      final api = ApiService(client: MockClient((_) async {
        return http.Response('', 204, headers: {'x-tile-changed': '0'});
      }));

      final result =
          await api.freshenVectorTile(zone: 'yow', z: 12, x: 1, y: 2);

      expect(result.changed, isFalse);
      expect(result.body, isNull);
    });

    test('an error is still unknown even if it carries a change header',
        () async {
      final api = ApiService(client: MockClient((_) async {
        return http.Response('', 503, headers: {'x-tile-changed': '0'});
      }));

      final result =
          await api.freshenVectorTile(zone: 'yow', z: 13, x: 1, y: 2);

      expect(result.changed, isNull);
      expect(result.body, isNull);
    });
  });

  test('z14 fetches each new body, including an unchanged server verdict',
      () async {
    var calls = 0;
    final api = ApiService(client: MockClient((request) async {
      expect(request.headers.containsKey('if-none-match'), isFalse);
      expect(request.url.queryParameters['fresh'], '1');
      calls++;
      return http.Response.bytes([calls], 200,
          headers: {'x-tile-changed': calls == 1 ? '1' : '0'});
    }));

    final first = await api.freshenVectorTile(zone: 'yow', z: 14, x: 1, y: 2);
    final next = await api.freshenVectorTile(zone: 'yow', z: 14, x: 1, y: 2);

    expect(calls, 2);
    expect(first.body, [1]);
    expect(next.body, [2]);
    expect(first.changed, isTrue);
    expect(next.changed, isFalse);
  });

  test('an unsolicited z14 304 cannot replace the body needed for the patch',
      () async {
    final api = ApiService(client: MockClient((_) async {
      return http.Response('', 304, headers: {'x-tile-changed': '1'});
    }));

    final result = await api.freshenVectorTile(zone: 'yow', z: 14, x: 1, y: 2);

    expect(result.changed, isNull);
    expect(result.body, isNull);
  });
}
