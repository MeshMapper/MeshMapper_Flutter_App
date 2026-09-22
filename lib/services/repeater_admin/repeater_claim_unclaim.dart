import 'repeater_admin_api.dart';
import 'repeater_claims_cache.dart';

typedef RepeaterUnclaimRequest = Future<RepeaterAdminResult> Function(
    String repeaterHex);

/// Runs an unclaim without allowing a companion change to redirect its cache
/// update to a different radio.
///
/// The provider supplies its state and side effects, keeping cache assignment,
/// UI notification, and persistence under `AppStateProvider` ownership.
class RepeaterClaimUnclaim {
  final RepeaterUnclaimRequest _request;
  final String? Function() _companionPublicKey;
  final RepeaterClaimsCache Function() _cache;
  final void Function(RepeaterClaimsCache cache) _replaceCache;
  final void Function() _notify;
  final void Function() _persist;

  RepeaterClaimUnclaim({
    required RepeaterUnclaimRequest request,
    required String? Function() companionPublicKey,
    required RepeaterClaimsCache Function() cache,
    required void Function(RepeaterClaimsCache cache) replaceCache,
    required void Function() notify,
    required void Function() persist,
  })  : _request = request,
        _companionPublicKey = companionPublicKey,
        _cache = cache,
        _replaceCache = replaceCache,
        _notify = notify,
        _persist = persist;

  Future<RepeaterAdminResult> run(String repeaterHex) async {
    final requestCompanionKey = _companionPublicKey();
    final result = await _request(repeaterHex);
    if (!result.ok) return result;

    _replaceCache(
        _cache().removeForCompanion(requestCompanionKey, repeaterHex));
    _notify();
    _persist();
    return result;
  }
}
