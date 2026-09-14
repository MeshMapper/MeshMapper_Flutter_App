import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/repeater_admin/repeater_admin_api.dart';
import 'package:mesh_mapper/services/repeater_admin/repeater_admin_models.dart';
import 'package:mesh_mapper/services/repeater_admin/repeater_claim_unclaim.dart';
import 'package:mesh_mapper/services/repeater_admin/repeater_claims_cache.dart';

final companionA = 'AA' * 32;
final companionB = 'BB' * 32;
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
  test('unclaim keeps the new companion cache when the response arrives late',
      () async {
    var currentCompanion = companionA;
    var cache = RepeaterClaimsCache({
      companionA: [claimA],
      companionB: [claimA, claimB],
    });
    var notifications = 0;
    var persistenceWrites = 0;
    final response = Completer<RepeaterAdminResult>();
    final unclaim = RepeaterClaimUnclaim(
      request: (_) => response.future,
      companionPublicKey: () => currentCompanion,
      cache: () => cache,
      replaceCache: (replacement) => cache = replacement,
      notify: () => notifications++,
      persist: () => persistenceWrites++,
    );

    final pending = unclaim.run(repeaterA);
    currentCompanion = companionB;
    response.complete(const RepeaterAdminResult(ok: true));

    await pending;

    expect(cache.claimsFor(companionA), isEmpty);
    expect(cache.claimsFor(companionB).map((claim) => claim.repeaterHex),
        [repeaterA, repeaterB]);
    expect(notifications, 1);
    expect(persistenceWrites, 1);
  });
}
