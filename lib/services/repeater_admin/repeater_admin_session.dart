import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../utils/debug_logger_io.dart';
import '../meshcore/connection.dart';
import 'repeater_admin_models.dart';

enum RepeaterAdminState { idle, ensuringContact, loggingIn, admin, guest, failed }

/// The firmware floor. Companion: enforced before a session opens. Repeater:
/// detected at login, because a repeater older than v1.9.0 sends no
/// firmware-level byte and the companion forwards the cipher's zero pad
/// byte in its place, so a level of 0 is that repeater.
const String kCompanionFirmwareFloorSentence =
    'Manage needs companion firmware v1.9.0 or newer.';
const String kRepeaterFirmwareFloorSentence =
    'This repeater seems to be running firmware older than v1.9.0. '
    'Manage needs repeater firmware v1.9.0 or newer.';
const String kAclUnansweredSentence =
    'The repeater did not confirm admin access.';
const String kNeighboursUnansweredSentence =
    "This repeater's firmware cannot report neighbours.";

/// One repeater, one radio, one mesh conversation.
///
/// Owns Section 1 of the spec: make sure the radio has the repeater as a
/// contact, log in, prove admin with the access-list request, read and reset
/// the learned route, read the neighbour table one page per tap (fetch, then
/// load more). Nothing here runs on its own: every request is a user tap,
/// and everything is a request with a pushed response; the radio's message
/// queue is never read. Depends on
/// [MeshCoreConnection] only and never touches the provider; the sheet
/// listens to it as a [ChangeNotifier].
///
/// Commands never overlap: the companion keeps a single pending request and a
/// login clears it, so [busy] serialises every public method.
class RepeaterAdminSession extends ChangeNotifier {
  final MeshCoreConnection _connection;
  final RepeaterTarget target;
  final int hopBytes;
  final String? Function(String hopHex)? _hopNameFor;
  final String? Function(String prefixHex)? _neighbourNameFor;
  final Duration timeoutMargin;
  final Duration minTimeout;
  final Duration maxTimeout;
  final Random _random;

  RepeaterAdminState _state = RepeaterAdminState.idle;
  String? _lastError;
  RepeaterRoute? _route;
  AdminProof? _proof;
  List<RepeaterNeighbour> _neighbours = const [];
  int _neighboursTotal = 0;
  int _neighbourPagesFetched = 0;
  DateTime? _neighboursFetchedAt;
  bool _neighboursExhausted = false;
  bool _busy = false;
  bool _closed = false;
  bool _disposed = false;
  bool _routeStale = false;
  LoginResult? _login;
  StreamSubscription<Uint8List>? _pathSub;

  RepeaterAdminSession({
    required MeshCoreConnection connection,
    required this.target,
    required this.hopBytes,
    String? Function(String hopHex)? hopNameFor,
    String? Function(String prefixHex)? neighbourNameFor,
    this.timeoutMargin = const Duration(seconds: 5),
    this.minTimeout = const Duration(seconds: 8),
    this.maxTimeout = const Duration(seconds: 60),
    Random? random,
  })  : _connection = connection,
        _hopNameFor = hopNameFor,
        _neighbourNameFor = neighbourNameFor,
        _random = random ?? Random.secure() {
    _pathSub = _connection.pathUpdatedStream.listen(_onPathUpdated);
    debugLog('[RADMIN] Session opened for ${target.shortId} (${target.name})');
  }

  RepeaterAdminState get state => _state;
  String? get lastError => _lastError;
  RepeaterRoute? get route => _route;
  AdminProof? get proof => _proof;
  List<RepeaterNeighbour> get neighbours => List.unmodifiable(_neighbours);
  int get neighboursTotal => _neighboursTotal;
  int get neighbourPagesFetched => _neighbourPagesFetched;
  DateTime? get neighboursFetchedAt => _neighboursFetchedAt;
  bool get busy => _busy;
  bool get closed => _closed;
  bool get isAdmin => _state == RepeaterAdminState.admin;
  bool get isLoggedIn =>
      _state == RepeaterAdminState.admin || _state == RepeaterAdminState.guest;

  /// The radio's est_timeout_ms plus the margin, clamped.
  Duration timeoutFor(int estTimeoutMs) {
    final wait = Duration(milliseconds: estTimeoutMs) + timeoutMargin;
    if (wait < minTimeout) return minTimeout;
    if (wait > maxTimeout) return maxTimeout;
    return wait;
  }

  String describeRoute() =>
      (_route ?? const RepeaterRoute.flood()).describe(_hopNameFor ?? (_) => null);

  /// Log in with [password]. Returns true only for a proven-flag admin login.
  /// A guest login returns false with [state] `guest` and no error; every
  /// failure returns false with a sentence in [lastError].
  Future<bool> login(String password) async {
    if (!_begin()) return false;
    _proof = null;
    _login = null;
    try {
      _setState(RepeaterAdminState.ensuringContact);
      await _ensureContact();
      _setState(RepeaterAdminState.loggingIn);
      final result = await _connection.login(
        target.publicKey,
        password,
        replyTimeout: timeoutFor,
      );
      _login = result;
      if (!result.success) {
        _fail('The repeater rejected the login.');
        return false;
      }
      if ((result.fwLevel ?? 0) == 0) {
        debugLog('[RADMIN] Login reply carries firmware level 0: '
            'repeater older than v1.9.0');
        _fail(kRepeaterFirmwareFloorSentence);
        return false;
      }
      if (!result.isAdmin) {
        debugLog('[RADMIN] Logged in as guest');
        _setState(RepeaterAdminState.guest);
        return false;
      }
      debugLog('[RADMIN] Logged in as admin (fw_level=${result.fwLevel})');
      _setState(RepeaterAdminState.admin);
      return true;
    } on TimeoutException {
      _fail('No reply from the repeater. Check the password and try again.');
      return false;
    } on FormatException catch (e) {
      // A LOGIN_SUCCESS shorter than 14 bytes: companion firmware older than
      // v1.9.0. The Manage gate should have refused earlier; say so anyway.
      debugWarn('[RADMIN] Unsupported login reply: $e');
      _fail(kCompanionFirmwareFloorSentence);
      return false;
    } on RepeaterAdminFailure catch (e) {
      _fail(e.message);
      return false;
    } on RadioErrorException catch (e) {
      _fail(_radioErrorSentence(e));
      return false;
    } on RadioAbortedException {
      _fail('The radio disconnected.');
      return false;
    } catch (e) {
      debugError('[RADMIN] Login failed: $e');
      _fail('Something went wrong talking to the radio.');
      return false;
    } finally {
      _end();
    }
  }

  /// Send the admin-only access-list request. A reply is the proof; silence
  /// is exactly what a guest sees, so a timeout refuses the claim.
  Future<bool> proveAdmin() async {
    if (!isAdmin) {
      _lastError = 'Log in with the admin password first.';
      _notify();
      return false;
    }
    if (!_begin()) return false;
    try {
      final data = await _connection.sendBinaryRequest(
        target.publicKey,
        buildAccessListRequest(),
        replyTimeout: timeoutFor,
      );
      final acl = parseAccessList(data);
      final own = _connection.selfInfo?.publicKey;
      var ownIsAdmin = false;
      for (final e in acl.entries) {
        if (own != null && _prefixMatches(e.prefix, own)) {
          ownIsAdmin = e.isAdmin;
        }
      }
      // The entries are read for the proof and discarded: never shown,
      // never uploaded, never logged beyond the count.
      _proof = AdminProof(
        loginAdmin: true,
        aclConfirmed: true,
        aclPerms: _login?.aclPerms,
        fwLevel: _login?.fwLevel,
        aclEntries: acl.entries.length,
        ownEntryIsAdmin: own == null ? acl.entries.any((e) => e.isAdmin) : ownIsAdmin,
      );
      _lastError = null;
      debugLog('[RADMIN] Admin proven: ACL answered with ${acl.entries.length} entries');
      return true;
    } on TimeoutException {
      _proof = AdminProof(
        loginAdmin: true,
        aclConfirmed: false,
        aclPerms: _login?.aclPerms,
        fwLevel: _login?.fwLevel,
        aclEntries: 0,
        ownEntryIsAdmin: false,
      );
      _lastError = kAclUnansweredSentence;
      debugWarn('[RADMIN] ACL request unanswered, claim refused');
      return false;
    } on RadioErrorException catch (e) {
      _lastError = _radioErrorSentence(e);
      return false;
    } on RadioAbortedException {
      _fail('The radio disconnected.');
      return false;
    } on FormatException catch (e) {
      debugWarn('[RADMIN] ACL reply malformed: $e');
      _lastError = kAclUnansweredSentence;
      return false;
    } finally {
      _end();
    }
  }

  /// Re-read the contact and render its out_path.
  Future<void> readRoute() async {
    if (!_begin()) {
      _routeStale = true;
      return;
    }
    try {
      final contacts = await _connection.getContacts();
      final c = _findContact(contacts);
      if (c != null) {
        _route = RepeaterRoute.fromRouteBytes(c.routeBytes, hopBytes: hopBytes);
        debugLog('[RADMIN] Route: ${describeRoute()}');
      }
    } on RadioAbortedException {
      _fail('The radio disconnected.');
    } catch (e) {
      debugWarn('[RADMIN] Route read failed: $e');
    } finally {
      _end();
    }
  }

  /// CMD_RESET_PATH. The next request floods and the route is relearned.
  Future<bool> resetRoute() async {
    if (!_begin()) return false;
    try {
      await _connection.resetPath(target.publicKey);
      _route = const RepeaterRoute.flood();
      _lastError = null;
      debugLog('[RADMIN] Route reset to flood');
      return true;
    } on RadioErrorException catch (e) {
      _lastError = _radioErrorSentence(e);
      return false;
    } on TimeoutException {
      _lastError = 'The radio did not confirm the reset.';
      return false;
    } on RadioAbortedException {
      _fail('The radio disconnected.');
      return false;
    } finally {
      _end();
    }
  }

  /// True when a Load more would ask for another page: a fetch has
  /// happened, the repeater reported more than we hold, the last page was
  /// not empty, and the 30-page brake has not tripped.
  bool get hasMoreNeighbours =>
      _neighboursFetchedAt != null &&
      !_neighboursExhausted &&
      _neighbours.length < _neighboursTotal &&
      _neighbourPagesFetched < kNeighbourMaxPages;

  /// Fetch the FIRST page of the neighbour table (ten entries, newest first),
  /// replacing anything held. Never called automatically; the user taps.
  Future<bool> fetchNeighbours() async {
    if (!_begin()) return false;
    _neighbours = const [];
    _neighboursTotal = 0;
    _neighbourPagesFetched = 0;
    _neighboursFetchedAt = null;
    _neighboursExhausted = false;
    _notify();
    try {
      return await _fetchNeighbourPage(offset: 0);
    } finally {
      _end();
    }
  }

  /// Fetch the NEXT page, appending. Refused (false, no write) when
  /// [hasMoreNeighbours] is false. A failed page keeps what was held, so the
  /// user can tap again.
  Future<bool> loadMoreNeighbours() async {
    if (!hasMoreNeighbours) {
      debugLog('[RADMIN] Load more refused: nothing more to fetch');
      return false;
    }
    if (!_begin()) return false;
    try {
      return await _fetchNeighbourPage(offset: _neighbours.length);
    } finally {
      _end();
    }
  }

  /// One GET_NEIGHBOURS round trip at [offset]. Caller holds the busy slot.
  Future<bool> _fetchNeighbourPage({required int offset}) async {
    try {
      final data = await _connection.sendBinaryRequest(
        target.publicKey,
        buildNeighbourRequest(offset: offset, random: _random.nextInt(1 << 32)),
        replyTimeout: timeoutFor,
      );
      final page = parseNeighbourPage(data, prefixLen: kNeighbourPrefixLen);
      _neighbourPagesFetched++;
      _neighboursTotal = page.total;
      _neighbours = List.unmodifiable([
        ..._neighbours,
        ...page.entries.map(
            (n) => n.withName(_neighbourNameFor?.call(n.prefixHex))),
      ]);
      if (page.returned == 0) _neighboursExhausted = true;
      if (_neighbourPagesFetched >= kNeighbourMaxPages &&
          _neighbours.length < page.total) {
        debugWarn('[RADMIN] Neighbour pager stopped at the '
            '$kNeighbourMaxPages page brake');
      }
      _neighboursFetchedAt ??= DateTime.now();
      _lastError = null;
      debugLog('[RADMIN] Neighbours page $_neighbourPagesFetched: '
          '${page.returned} of ${page.total} (offset $offset, '
          'held ${_neighbours.length}, more=$hasMoreNeighbours)');
      return true;
    } on TimeoutException {
      _lastError = kNeighboursUnansweredSentence;
      return false;
    } on RadioErrorException catch (e) {
      _lastError = e.errorCode == 1
          ? kNeighboursUnansweredSentence
          : _radioErrorSentence(e);
      return false;
    } on FormatException {
      _lastError = kNeighboursUnansweredSentence;
      return false;
    } on RadioAbortedException {
      _fail('The radio disconnected.');
      return false;
    }
  }

  /// Stop listening and abort anything in flight. Idempotent.
  void close() {
    if (_closed) return;
    _closed = true;
    _pathSub?.cancel();
    _pathSub = null;
    _connection.abortPendingAdmin();
    debugLog('[RADMIN] Session closed for ${target.shortId}');
  }

  @override
  void dispose() {
    _disposed = true;
    close();
    super.dispose();
  }

  // ---- internals ----

  /// Guards every [notifyListeners] call: a command suspended past [close]
  /// resumes and reports its outcome after this notifier is disposed
  /// ([dispose] runs [close] first), and a disposed [ChangeNotifier] throws
  /// on notify. Once [_disposed] is set nothing here notifies again.
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  bool _begin() {
    if (_closed || _busy) {
      debugLog('[RADMIN] Command refused: ${_closed ? 'closed' : 'busy'}');
      return false;
    }
    _busy = true;
    _notify();
    return true;
  }

  void _end() {
    _busy = false;
    _notify();
    if (_routeStale && !_closed) {
      _routeStale = false;
      unawaited(readRoute());
    }
  }

  void _setState(RepeaterAdminState s) {
    _state = s;
    _notify();
  }

  void _fail(String message) {
    _lastError = message;
    _state = RepeaterAdminState.failed;
    _notify();
  }

  Future<void> _ensureContact() async {
    final contacts = await _connection.getContacts();
    final existing = _findContact(contacts);
    if (existing != null) {
      // Leave it alone: an add would wipe the learned route.
      _route = RepeaterRoute.fromRouteBytes(existing.routeBytes, hopBytes: hopBytes);
      debugLog('[RADMIN] Contact present, route: ${describeRoute()}');
      return;
    }
    final record = ContactRecord.newRepeater(
      publicKey: target.publicKey,
      name: target.name,
      lat: target.lat,
      lon: target.lon,
      nowSecs: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    try {
      await _connection.addContact(record);
    } on RadioErrorException catch (e) {
      if (e.isTableFull) {
        throw const RepeaterAdminFailure("Your radio's contact list is full.");
      }
      rethrow;
    }
    _route = const RepeaterRoute.flood();
    debugLog('[RADMIN] Contact added as a flood repeater');
  }

  ContactRecord? _findContact(List<ContactRecord> contacts) {
    for (final c in contacts) {
      if (c.publicKeyHex == target.hexId) return c;
    }
    return null;
  }

  void _onPathUpdated(Uint8List key) {
    if (_closed) return;
    if (bytesToHex(key) != target.hexId) return;
    debugLog('[RADMIN] Route updated by the radio');
    if (_busy) {
      _routeStale = true;
    } else {
      unawaited(readRoute());
    }
  }

  static bool _prefixMatches(Uint8List prefix, Uint8List key) {
    if (key.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (prefix[i] != key[i]) return false;
    }
    return true;
  }

  String _radioErrorSentence(RadioErrorException e) {
    if (e.isNotFound) return 'Your radio does not know this repeater.';
    if (e.isTableFull) return 'Your radio could not send the request. Try again.';
    return 'The radio refused the command (code ${e.errorCode}).';
  }
}
