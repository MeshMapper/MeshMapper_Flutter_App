import '../../utils/debug_logger_io.dart';
import 'repeater_admin_models.dart';
import 'repeater_admin_session.dart';

/// One job, one payload. The session owns the mesh conversation; a module
/// turns what the session learned into the body of one server action. A
/// later module (status, telemetry) is one class here and one server action.
abstract class RepeaterAdminModule {
  String get name;
  bool get needsAdmin;

  /// Produce the payload, or throw [RepeaterAdminFailure] with a sentence.
  Future<Map<String, dynamic>> run(RepeaterAdminSession session);
}

/// Login admin flag plus the access-list reply, as the `claim` proof.
class ClaimModule implements RepeaterAdminModule {
  @override
  String get name => 'claim';

  @override
  bool get needsAdmin => true;

  @override
  Future<Map<String, dynamic>> run(RepeaterAdminSession session) async {
    if (!session.isAdmin) {
      throw const RepeaterAdminFailure(
          'That is the guest password. Claiming needs the admin password.');
    }
    final proven =
        session.proof?.isProven == true || await session.proveAdmin();
    if (!proven) {
      throw RepeaterAdminFailure(session.lastError ?? kAclUnansweredSentence);
    }
    debugLog('[RADMIN] Claim payload ready for ${session.target.shortId}');
    return session.proof!.toWire();
  }
}

/// The pages the session has fetched so far (the user chose how many with
/// Load more), capped for upload. `total` is the repeater's own count, so
/// the server knows the upload may be partial.
class NeighboursModule implements RepeaterAdminModule {
  @override
  String get name => 'neighbours';

  @override
  bool get needsAdmin => true;

  @override
  Future<Map<String, dynamic>> run(RepeaterAdminSession session) async {
    final fetchedAt = session.neighboursFetchedAt;
    if (fetchedAt == null) {
      throw const RepeaterAdminFailure('Fetch the neighbours first.');
    }
    return payloadFor(
        entries: session.neighbours,
        total: session.neighboursTotal,
        fetchedAt: fetchedAt);
  }

  static Map<String, dynamic> payloadFor({
    required List<RepeaterNeighbour> entries,
    required int total,
    required DateTime fetchedAt,
  }) {
    final capped = entries.length > kNeighbourUploadCap
        ? entries.sublist(0, kNeighbourUploadCap)
        : entries;
    return {
      'fetched_at': fetchedAt.millisecondsSinceEpoch ~/ 1000,
      'total': total,
      'entries': capped.map((n) => n.toWire()).toList(),
    };
  }
}
