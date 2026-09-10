import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/repeater_admin/repeater_admin_models.dart';
import 'package:mesh_mapper/services/repeater_admin/repeater_admin_module.dart';

void main() {
  test('NeighboursModule shapes and caps the table', () {
    final entries = List<RepeaterNeighbour>.generate(
        305,
        (i) => RepeaterNeighbour(
            prefixHex: i.toRadixString(16).padLeft(16, '0').toUpperCase(),
            heardSecsAgo: i,
            snrDb: -1.5));
    final payload = NeighboursModule.payloadFor(
        entries: entries,
        total: 400,
        fetchedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000));
    expect(payload['fetched_at'], 1700000000);
    expect(payload['total'], 400);
    expect((payload['entries'] as List).length, kNeighbourUploadCap);
    expect((payload['entries'] as List).first,
        {'prefix': '0' * 16, 'snr': -1.5, 'heard_secs_ago': 0});
  });

  test('ClaimModule needs admin, NeighboursModule needs admin', () {
    expect(ClaimModule().needsAdmin, isTrue);
    expect(NeighboursModule().needsAdmin, isTrue);
    expect(ClaimModule().name, 'claim');
    expect(NeighboursModule().name, 'neighbours');
  });
}
