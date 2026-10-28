import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart';

/// A zone check that got no answer was retried every 5 s for as long as the
/// network stayed down: one Android phone whose background network was cut
/// logged about 500 tries, twelve a minute for 20 minutes at a time. In a
/// server outage every phone would hit /status that hard. Retries now back
/// off to once a minute, and any real answer starts again from 5 s.
void main() {
  test('backs off 5, 10, 20, 40, then every 60 seconds', () {
    expect([for (var n = 1; n <= 7; n++) zoneCheckNetworkRetrySeconds(n)],
        [5, 10, 20, 40, 60, 60, 60]);
  });

  test('a long outage never overflows past the cap', () {
    expect(zoneCheckNetworkRetrySeconds(500), 60);
  });

  test('the first failure retries quickly', () {
    expect(zoneCheckNetworkRetrySeconds(0), 5);
    expect(zoneCheckNetworkRetrySeconds(1), 5);
  });
}
