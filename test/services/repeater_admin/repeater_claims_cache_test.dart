import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/repeater_admin/repeater_admin_models.dart';
import 'package:mesh_mapper/services/repeater_admin/repeater_claims_cache.dart';

final companionA = 'AA' * 32;
final companionB = 'BB' * 32;
final companionC = 'CC' * 32;
final repeaterA = '11' * 32;
final repeaterB = '22' * 32;

final claimA = RepeaterClaim(
  repeaterHex: repeaterA,
  name: 'North Hill',
  claimedAt: 1,
  updatedAt: 2,
);

final claimB = RepeaterClaim(
  repeaterHex: repeaterB,
  name: 'South Hill',
  claimedAt: 3,
  updatedAt: 4,
);

void main() {
  test('returns the cached union only while no companion is connected', () {
    final cache = RepeaterClaimsCache({
      companionA: [claimA],
      companionB: [claimA, claimB],
    });

    expect(cache.claimsFor(null).map((claim) => claim.repeaterHex),
        [repeaterA, repeaterB]);
    expect(cache.claimsFor(companionA).map((claim) => claim.repeaterHex),
        [repeaterA]);
    expect(cache.claimsFor(companionC), isEmpty);
  });

  test('removes an unclaimed repeater only for the connected companion', () {
    final cache = RepeaterClaimsCache({
      companionA: [claimA],
      companionB: [claimA, claimB],
    }).removeForCompanion(companionA, repeaterA);

    expect(cache.claimsFor(companionA), isEmpty);
    expect(cache.claimsFor(companionB).map((claim) => claim.repeaterHex),
        [repeaterA, repeaterB]);
  });

  test('discards a mine response when the companion changed in flight', () {
    final cache = RepeaterClaimsCache({
      companionB: [claimB]
    });

    final updated = cache.replaceForCurrent(
      requestKey: companionA,
      currentKey: companionB,
      claims: [claimA],
    );

    expect(updated, isNull);
    expect(cache.claimsFor(companionA), isEmpty);
    expect(cache.claimsFor(companionB), [claimB]);
  });
}
