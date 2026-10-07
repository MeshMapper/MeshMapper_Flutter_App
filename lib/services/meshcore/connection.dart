import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../models/connection_state.dart';
import '../../models/device_model.dart';
import '../../utils/debug_logger_io.dart';
import '../../utils/radio_filter.dart';
import '../transport/companion_transport.dart';
import 'buffer_utils.dart';
import 'channel_service.dart';
import 'crypto_service.dart';
import 'packet_parser.dart';
import 'protocol_constants.dart';
import 'scope_lease.dart';

/// How long a repeater-admin command waits for an in-flight noise floor or
/// battery poll to settle before it writes anyway.
///
/// Both polls carry a 5s timeout of their own, so this only fires when a
/// settle future is left uncompleted. Longer than the polls so a normal drain
/// never trips it.
const Duration kPollDrainTimeout = Duration(seconds: 6);

/// How long a reply stays owed in the reply ledger after its write returns.
const Duration kReplyOwedExpiry = Duration(seconds: 10);

/// How long a contact stream may go without a frame before scope discovery
/// is suspended for the rest of the connection.
const Duration kContactsStreamSilence = Duration(seconds: 60);

/// How long [MeshCoreConnection.sign] waits for scope discovery to let go of
/// the radio before it fails with `busy`.
const Duration kSignScopeWait = Duration(seconds: 15);

/// Response from device query command
class DeviceQueryResponse {
  /// Companion FIRMWARE_VER_CODE (byte 1 of RESP_CODE_DEVICE_INFO).
  /// Describes companion API capabilities, independent of the release string.
  final int protocolVersion;
  final String manufacturer;

  /// Number of channel slots advertised in device-info byte 3.
  /// Null when the parsed format has no capacity or reports zero.
  final int? maxChannels;
  final String? firmwareBuildDate; // Added in protocol v8
  final String?
      firmwareVersionString; // e.g. "v1.14.0-9f1a3ea" (v7+, 20-byte C-string)
  final int?
      pathHashMode; // 0=1-byte, 1=2-byte, 2=3-byte (null if old firmware, v10+)

  const DeviceQueryResponse({
    required this.protocolVersion,
    required this.manufacturer,
    this.maxChannels,
    this.firmwareBuildDate,
    this.firmwareVersionString,
    this.pathHashMode,
  });
}

/// Response from AppStart/SelfInfo command
/// Contains device identity including public key
class SelfInfo {
  final int type;
  final int txPower;
  final int maxTxPower;
  final Uint8List publicKey;
  final String name;

  /// Radio configuration reported in the SelfInfo response (newer firmware only;
  /// null on older firmware that omits the radio block). Encoding as sent by the device:
  /// frequency in kHz, bandwidth in Hz, SF/CR raw. (The companion-protocol wiki documents
  /// freq as Hz, but real hardware reports kHz — a 910.525 MHz radio sends 910525.)
  final int? radioFreqKHz;
  final int? radioBwHz;
  final int? radioSf;
  final int? radioCr;

  const SelfInfo({
    required this.type,
    required this.txPower,
    required this.maxTxPower,
    required this.publicKey,
    required this.name,
    this.radioFreqKHz,
    this.radioBwHz,
    this.radioSf,
    this.radioCr,
  });

  /// Get public key as hex string
  String get publicKeyHex => publicKey
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join('')
      .toUpperCase();

  /// Whether the device reported a usable radio configuration.
  bool get hasRadioConfig => radioFreqKHz != null && radioFreqKHz! > 0;

  /// Compact radio config for the API: "freqMHz,bwKHz,SF,CR" (e.g. "910.525,62.5,7,5").
  /// Frequency kHz→MHz (÷1000), bandwidth Hz→kHz (÷1000). Null when no radio params.
  String? get radioConfigApi {
    if (!hasRadioConfig) return null;
    final freq = _trimNum(radioFreqKHz! / 1e3);
    final bw = _trimNum((radioBwHz ?? 0) / 1e3);
    return '$freq,$bw,${radioSf ?? 0},${radioCr ?? 0}';
  }

  /// The region-door filter for this radio's preset: `f_freq`, `f_bw`,
  /// `f_sf` from [radioConfigApi] (no coding rate). Deliberately NOT the
  /// app's filter source: this reflects only the live connection, and the
  /// app needs a filter while disconnected too. The app reads its filter
  /// from `AppStateProvider.radioFilterQuery`, which falls back to the last
  /// connected radio's configuration while disconnected, so the map keeps
  /// painting the right preset between sessions. Null when the radio did
  /// not report a usable configuration. See `lib/utils/radio_filter.dart`.
  Map<String, String>? get radioFilterQuery =>
      radioFilterFromTag(radioConfigApi);

  /// Human-readable radio config for the UI: "910.525 MHz · 62.5 kHz · SF7 · CR5".
  /// Null when unavailable.
  String? get radioConfigDisplay {
    if (!hasRadioConfig) return null;
    final freq = _trimNum(radioFreqKHz! / 1e3);
    final bw = _trimNum((radioBwHz ?? 0) / 1e3);
    return '$freq MHz · $bw kHz · SF${radioSf ?? 0} · CR${radioCr ?? 0}';
  }

  /// Format a number with up to 3 decimals, trimming trailing zeros and a trailing dot
  /// (910.525 → "910.525", 62.5 → "62.5", 915.0 → "915").
  static String _trimNum(double v) {
    var s = v.toStringAsFixed(3);
    if (s.contains('.')) {
      s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    }
    return s;
  }
}

/// Thrown by [MeshCoreConnection.sign] for protocol-level sign failures.
///
/// [code] is stable and is what callers branch on:
/// * `unsupported`          — the radio answered CMD_SIGN_START with ERR (old firmware)
/// * `data_too_long`        — payload exceeds the radio's `maxSignDataLen`
/// * `malformed_response`   — a truncated RESP_SIGN_START / RESP_SIGNATURE frame
/// * `bad_signature_length` — the radio returned something other than 64 bytes
/// * `err`                  — the radio answered ERR mid-sign
/// * `aborted`              — the connection closed while a sign was in flight
/// * `busy` (transient): scope discovery held the radio for the whole wait;
///   the link flow retries it with its usual backoff
class SignException implements Exception {
  final String code;
  final String message;

  const SignException(this.code, this.message);

  @override
  String toString() => 'SignException($code): $message';
}

/// Thrown when the radio answers a repeater-admin command with ERR.
class RadioErrorException implements Exception {
  final String command;
  final int errorCode; // ErrorCodes.*

  const RadioErrorException(this.command, this.errorCode);

  bool get isNotFound => errorCode == ErrorCodes.notFound;
  bool get isTableFull => errorCode == ErrorCodes.tableFull;

  @override
  String toString() => 'RadioErrorException($command, code $errorCode)';
}

/// Thrown into a pending query (stats, channel info, device query, export
/// contact, get time) when the radio answers ERR. Carries the firmware's
/// error code so a caller can tell the end of a list (ERR_CODE_NOT_FOUND)
/// from a fault, and reads in logs exactly as the plain exception it replaced.
class CommandErrorException implements Exception {
  final int errorCode; // ErrorCodes.*

  const CommandErrorException(this.errorCode);

  bool get isNotFound => errorCode == ErrorCodes.notFound;

  @override
  String toString() => 'Exception: Command error (code $errorCode)';
}

/// Thrown into every pending repeater-admin completer when the connection
/// closes mid-command (the `_abortPendingSign` pattern).
class RadioAbortedException implements Exception {
  const RadioAbortedException();

  @override
  String toString() => 'RadioAbortedException: connection closed';
}

class _AdminCommandToken {
  final String name;

  const _AdminCommandToken(this.name);
}

/// A send whose own bare OK or ERR the connection claims.
enum _OwnReplyKind { tx, discovery, channel }

/// One pending claim on the next OK or ERR, queued as its frame goes out.
class _OwnReplyClaim {
  final _OwnReplyKind kind;

  /// Completes when the reply arrives, the claim expires, or it is released.
  final Completer<void> reply = Completer<void>();
  Timer? expiry;

  /// True once the radio answered with OK or ERR (not expired or released).
  bool answered = false;

  /// The ERR code the radio answered with, null on OK or no answer.
  int? errorCode;

  _OwnReplyClaim(this.kind);

  String get label => switch (kind) {
        _OwnReplyKind.tx => 'TX send',
        _OwnReplyKind.discovery => 'discovery request',
        _OwnReplyKind.channel => 'channel write',
      };

  void settle() {
    expiry?.cancel();
    expiry = null;
    if (!reply.isCompleted) reply.complete();
  }
}

/// How many reply frames one outbound command earns from the companion
/// firmware (`examples/companion_radio/MyMesh.cpp`, `handleCmdFrame`).
class CommandReplyShape {
  /// Reply frames owed: normally one, zero for the commands that reboot or
  /// wipe the radio.
  final int replies;

  /// The reply is push 0x8B (self telemetry), not a code below 0x80.
  final bool selfTelemetry;

  /// CMD_GET_CONTACTS: one initial reply, then a stream tracked on its own.
  final bool opensContactStream;

  const CommandReplyShape(
      {this.replies = 1,
      this.selfTelemetry = false,
      this.opensContactStream = false});
}

/// Where a CMD_GET_CONTACTS stream stands: written but not started,
/// streaming, or neither.
enum ContactsStreamState { none, requested, open }

/// One reply the radio still owes, oldest first in the ledger.
class _OwedReply {
  final int command;
  final bool selfTelemetry;
  final bool opensContactStream;

  /// Written by a scope lease. Only these keep Manage waiting once the
  /// lease has ended: ordinary traffic owes replies too, and never did.
  final bool scopeOwned;
  Timer? expiry;

  _OwedReply(this.command,
      {required this.selfTelemetry,
      required this.opensContactStream,
      this.scopeOwned = false});
}

/// The parsed RESP_CODE_SENT frame: [flood:1][tag:4][est_timeout_ms:u32].
class SentInfo {
  final bool flood;
  final Uint8List tag;
  final int estTimeoutMs;

  const SentInfo(
      {required this.flood, required this.tag, required this.estTimeoutMs});
}

/// The pushed answer to CMD_SEND_LOGIN.
///
/// LOGIN_SUCCESS (14 bytes, companion firmware v1.9.0 and newer):
/// [0x85][is_admin:1][prefix:6][tag:4][acl_perms:1][fw_level:1].
/// A shorter push is older companion firmware, which the app does not
/// support; the parser completes the login with a FormatException.
/// LOGIN_FAIL (0x86) gives [success] false. A repeater older than v1.9.0
/// sends no firmware-level byte; the companion then forwards the cipher's
/// zero pad byte, so [fwLevel] 0 means "repeater older than v1.9.0".
class LoginResult {
  final bool success;
  final bool isAdmin;
  final Uint8List prefix;
  final int? aclPerms;
  final int? fwLevel;

  const LoginResult({
    required this.success,
    required this.isAdmin,
    required this.prefix,
    this.aclPerms,
    this.fwLevel,
  });
}

/// One contact as the radio stores it. The same 147-byte layout is read from
/// RESP_CODE_CONTACT and written to CMD_ADD_UPDATE_CONTACT:
/// [pubkey:32][type:1][flags:1][out_path_len:1][out_path:64][name:32]
/// [last_advert:u32][lat:i32 microdeg][lon:i32 microdeg][lastmod:u32]
class ContactRecord {
  static const int payloadLength = 32 + 1 + 1 + 1 + 64 + 32 + 4 + 4 + 4 + 4;

  final Uint8List publicKey;
  final int type;
  final int flags;
  final int outPathLen;
  final Uint8List outPath; // always 64 bytes
  final String name;

  /// The 32 name bytes exactly as the radio sent them (null for a record
  /// built here). Written back verbatim, so a restore is byte-exact even for
  /// a name that is not valid UTF-8 or carries bytes past its NUL.
  final Uint8List? rawName;
  final int lastAdvert;
  final int latMicro;
  final int lonMicro;
  final int lastMod;

  factory ContactRecord({
    required Uint8List publicKey,
    required int type,
    required int flags,
    required int outPathLen,
    required Uint8List outPath,
    required String name,
    required int lastAdvert,
    required int latMicro,
    required int lonMicro,
    required int lastMod,
    Uint8List? rawName,
  }) {
    if (publicKey.length != 32) {
      throw ArgumentError.value(
          publicKey.length, 'publicKey.length', 'must be exactly 32 bytes');
    }
    if (outPath.length != 64) {
      throw ArgumentError.value(
          outPath.length, 'outPath.length', 'must be exactly 64 bytes');
    }
    if (rawName != null && rawName.length != 32) {
      throw ArgumentError.value(
          rawName.length, 'rawName.length', 'must be exactly 32 bytes');
    }
    return ContactRecord._(
      publicKey: publicKey,
      type: type,
      flags: flags,
      outPathLen: outPathLen,
      outPath: outPath,
      name: name,
      lastAdvert: lastAdvert,
      latMicro: latMicro,
      lonMicro: lonMicro,
      lastMod: lastMod,
      rawName: rawName,
    );
  }

  ContactRecord._({
    required this.publicKey,
    required this.type,
    required this.flags,
    required this.outPathLen,
    required this.outPath,
    required this.name,
    required this.lastAdvert,
    required this.latMicro,
    required this.lonMicro,
    required this.lastMod,
    this.rawName,
  });

  /// A flood-route repeater contact with the MeshMapper name and position.
  factory ContactRecord.newRepeater({
    required Uint8List publicKey,
    required String name,
    required double lat,
    required double lon,
    required int nowSecs,
  }) {
    return ContactRecord(
      publicKey: publicKey,
      type: AdvTypes.repeater,
      flags: 0,
      outPathLen: ProtocolConstants.outPathUnknown,
      outPath: Uint8List(64),
      name: name,
      lastAdvert: nowSecs,
      latMicro: (lat * 1e6).round(),
      lonMicro: (lon * 1e6).round(),
      lastMod: nowSecs,
    );
  }

  /// Parse the payload after the code byte. Throws [FormatException] when
  /// fewer than [payloadLength] bytes remain.
  factory ContactRecord.parse(BufferReader reader) {
    if (reader.remainingBytesCount < payloadLength) {
      throw FormatException(
          'Contact frame carries ${reader.remainingBytesCount} bytes, '
          'expected $payloadLength');
    }
    final publicKey = reader.readBytes(32);
    final type = reader.readByte();
    final flags = reader.readByte();
    final outPathLen = reader.readByte();
    final outPath = reader.readBytes(64);
    final rawName = Uint8List.fromList(reader.readBytes(32));
    return ContactRecord(
      publicKey: publicKey,
      type: type,
      flags: flags,
      outPathLen: outPathLen,
      outPath: outPath,
      name: BufferReader(rawName).readCString(32),
      lastAdvert: reader.readUInt32LE(),
      latMicro: reader.readInt32LE(),
      lonMicro: reader.readInt32LE(),
      lastMod: reader.readUInt32LE(),
      rawName: rawName,
    );
  }

  String get publicKeyHex => publicKey
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();

  /// `out_path_len` is NOT a byte count. The firmware stores it in the
  /// packet path_len encoding (`Packet::copyPath`): the top two bits are the
  /// hop hash size less one, the low six bits the hop count. A one-hop route
  /// on a 3-byte-hop mesh is 0x81, and reading that as 129 bytes rendered the
  /// whole 64-byte buffer, stale hops and all, as 64 one-byte hops.
  int get routeHopCount =>
      outPathLen == ProtocolConstants.outPathUnknown ? 0 : outPathLen & 63;

  /// Bytes per hop in [routeBytes]: 1, 2 or 3 (4 is reserved by the firmware).
  int get routeHopBytes => (outPathLen >> 6) + 1;

  /// True when the radio has learned a route, which includes a ZERO-hop one
  /// (0x80 on a 3-byte-hop mesh): the repeater heard this radio directly and
  /// the radio sends to it direct with an empty path. Only 0xFF is unknown,
  /// which is when the radio floods.
  bool get hasRoute => outPathLen != ProtocolConstants.outPathUnknown;

  /// The learned path, `routeHopCount * routeHopBytes` bytes of `out_path`
  /// (empty when unknown, and empty for a direct zero-hop route).
  Uint8List get routeBytes => hasRoute
      ? outPath.sublist(
          0, (routeHopCount * routeHopBytes).clamp(0, outPath.length))
      : Uint8List(0);

  /// The same contact with no learned route (what CMD_RESET_PATH leaves).
  ContactRecord withRouteCleared() => ContactRecord(
        publicKey: publicKey,
        type: type,
        flags: flags,
        outPathLen: ProtocolConstants.outPathUnknown,
        outPath: Uint8List(64),
        name: name,
        lastAdvert: lastAdvert,
        latMicro: latMicro,
        lonMicro: lonMicro,
        lastMod: lastMod,
        rawName: rawName,
      );

  /// The same record, byte for byte, with only `out_path_len` replaced. The
  /// scope request borrows a zero-hop route with `withOutPathLen(0)`.
  ContactRecord withOutPathLen(int outPathLen) => ContactRecord(
        publicKey: publicKey,
        type: type,
        flags: flags,
        outPathLen: outPathLen,
        outPath: outPath,
        name: name,
        lastAdvert: lastAdvert,
        latMicro: latMicro,
        lonMicro: lonMicro,
        lastMod: lastMod,
        rawName: rawName,
      );

  Uint8List toFrame(int commandCode) {
    final w = BufferWriter();
    w.writeByte(commandCode);
    w.writeBytes(publicKey);
    w.writeByte(type);
    w.writeByte(flags);
    w.writeByte(outPathLen);
    w.writeBytes(outPath);
    final raw = rawName;
    if (raw != null) {
      w.writeBytes(raw);
    } else {
      w.writeCString(name, 32);
    }
    w.writeUInt32LE(lastAdvert);
    w.writeUInt32LE(latMicro.toUnsigned(32));
    w.writeUInt32LE(lonMicro.toUnsigned(32));
    w.writeUInt32LE(lastMod);
    return w.toBytes();
  }
}

/// MeshCore connection manager
/// Ported from content/mc/connection/connection.js in WebClient repo
///
/// Implements the 10-step connection workflow:
/// 1. BLE GATT Connect
/// 2. Protocol Handshake
/// 3. Device Info Query
/// 4. Device Identification (match device model for display/reporting)
/// 5. Time Sync
/// 6. API Capacity Check (slot acquisition)
/// 7. Channel Setup
/// 8. GPS Init
/// 9. Connected State
class MeshCoreConnection {
  final CompanionTransport _transport;
  bool _disposed = false;
  final _stepController = StreamController<ConnectionStep>.broadcast();
  final _channelMessageController =
      StreamController<ChannelMessage>.broadcast();
  final _rawDataController = StreamController<Map<String, dynamic>>.broadcast();
  final _logRxDataController =
      StreamController<({Uint8List raw, double snr, int rssi})>.broadcast();
  final _controlDataController =
      StreamController<({Uint8List raw, double snr, int rssi})>.broadcast();
  final _traceDataController = StreamController<Uint8List>.broadcast();
  final _noiseFloorController = StreamController<int>.broadcast();
  final _batteryController = StreamController<int>.broadcast();
  final _pathUpdatedController = StreamController<Uint8List>.broadcast();

  ConnectionStep _currentStep = ConnectionStep.disconnected;
  DeviceQueryResponse? _deviceInfo;
  DeviceModel? _deviceModel;
  ChannelInfo? _wardrivingChannel;
  StreamSubscription? _dataSubscription;

  // Completers for command responses
  Completer<DeviceQueryResponse>? _deviceQueryCompleter;
  Completer<SelfInfo>? _selfInfoCompleter;
  Completer<void>? _setTimeCompleter;
  Completer<ChannelInfo>? _channelInfoCompleter;

  /// The slot [_channelInfoCompleter] asked for. A CHANNEL_INFO for any other
  /// slot is a late reply to an earlier read and is not this request's answer.
  int? _channelInfoRequestedIdx;
  Completer<int>? _statsCompleter;
  Completer<String>? _exportContactCompleter;
  Completer<int>? _getTimeCompleter;

  // TX pings and discovery requests are answered with a bare OK or ERR (never
  // RESP_CODE_SENT), in command order. Each send queues a claim as its frame
  // reaches the wire, and the oldest claim takes the next OK or ERR: after a
  // pending sign, before the repeater-admin and time-sync owners. Without the
  // claim that reply went to whichever OK waiter happened to exist.
  final List<_OwnReplyClaim> _ownReplyClaims = [];

  /// How long a TX or discovery claim waits for its OK or ERR before it
  /// expires, so an unanswered send cannot swallow a later command's reply.
  /// Tests shorten it.
  @visibleForTesting
  Duration ownReplyTimeout = const Duration(seconds: 3);

  // Repeater-admin commands (contacts, login, binary request, reset path).
  // One at a time: the companion keeps a single pending request and a login
  // clears it (clearPendingReqs), so overlapping two would lose a reply.
  _AdminCommandToken? _adminCommandInFlight;
  Completer<SentInfo>? _adminSentCompleter;
  // A bare OK carries no command tag. After its caller times out, keep the
  // receiver and owner until that old reply, an ERR, or an abort drains it.
  Completer<void>? _adminOkCompleter;
  _AdminCommandToken? _adminOkOwner;
  bool _adminOkAwaitingLateResponse = false;
  // The late-response wait is not open ended: if that old reply never lands
  // (the radio dropped it), the backstop hands the slot back anyway.
  Timer? _adminLateResponseTimer;
  Completer<List<ContactRecord>>? _contactsCompleter;
  List<ContactRecord> _contactsBuffer = [];

  /// The radio's contact list as this connection last saw it, keyed by the
  /// full public key hex, in the radio's order. Lives exactly as long as
  /// this object (a BLE flap builds a new MeshCoreConnection). Primed by the
  /// first full read; every later [getContacts] asks the firmware only for
  /// contacts modified after [_contactSince] (the newest `lastmod` the
  /// END_OF_CONTACTS frame reported) and merges them in, so a 350-contact
  /// radio streams its 52 KB once per connection rather than once per
  /// login. A learned route bumps `lastmod` on the firmware side, so route
  /// changes arrive through the same sync; a CMD_RESET_PATH does not, so
  /// [resetPath] patches the cached record itself.
  final Map<String, ContactRecord> _contactCache = <String, ContactRecord>{};
  bool _contactCachePrimed = false;
  int _contactSince = 0;
  int _contactsEndLastmod = 0;
  Completer<LoginResult>? _loginCompleter;
  Uint8List? _loginPrefix; // first 6 bytes of the repeater key
  Completer<Uint8List>? _binaryResponseCompleter;
  Uint8List? _binaryResponseTag;

  // CMD_SIGN state. `_signGate` is non-null for the whole duration of a sign;
  // Task-4's write funnel queues every non-sign frame behind it so no other
  // command's OK can be mistaken for a per-chunk sign ack.
  bool _signInProgress = false;
  Completer<int>? _signStartCompleter; // resolves with maxSignDataLen
  Completer<void>? _signChunkOkCompleter; // resolves on each chunk's OK
  Completer<Uint8List>? _signatureCompleter; // resolves with the 64-byte sig
  Completer<void>? _signGate;

  // Device self info (contains public key)
  SelfInfo? _selfInfo;

  // Callback for auth request during connection workflow (Step 6)
  // Set by AppStateProvider before calling connect()
  // Returns auth result map or null on failure
  Future<Map<String, dynamic>?> Function()? onRequestAuth;

  // Noise floor tracking
  int? _lastNoiseFloor; // dBm or null if not supported
  Timer? _noiseFloorTimer;
  bool _isFetchingNoiseFloor = false;
  int _noiseFloorFailCount = 0;

  /// True while noise floor polling runs at [noiseFloorBackoffInterval]
  /// after [_noiseFloorFailLimit] failures in a row.
  bool _noiseFloorBackedOff = false;

  /// Consecutive failures before polling slows to the backoff interval.
  static const int _noiseFloorFailLimit = 3;

  /// Normal noise floor poll interval. Tests shorten it.
  @visibleForTesting
  Duration noiseFloorPollInterval = const Duration(seconds: 5);

  /// Slower poll interval used after repeated failures, so a radio that is
  /// briefly busy (an Android GATT busy run, a second app on the link) costs a
  /// few samples rather than the rest of the session. Tests shorten it.
  @visibleForTesting
  Duration noiseFloorBackoffInterval = const Duration(seconds: 30);

  // Battery tracking
  int? _lastBatteryMilliVolts; // millivolts or null if not supported
  Timer? _batteryTimer;

  /// Extra bytes on the last battery reply, so the extended-format note is
  /// logged when it changes instead of on every poll. -1 until the first
  /// reply, so that one always reports whatever shape it has.
  int _lastBatteryExtraBytes = -1;

  // Completes when the stats or battery request that is on the wire settles;
  // null when that poller is idle. Read by [_drainPollsForAdminCommand].
  Completer<void>? _statsRequestSettled;
  Completer<void>? _batteryRequestSettled;

  // ---- Scope discovery: reply ledger, contact stream, lease and listen ----
  //
  // The ledger holds one entry per reply frame the radio owes for commands
  // already written (see [_replyShape]). It is bookkeeping for the scope
  // lease only: it changes no dispatch outside a lease.
  final List<_OwedReply> _repliesOwed = [];

  /// How long an owed reply stays in the ledger after its write returns.
  /// Tests shorten it.
  @visibleForTesting
  Duration replyOwedExpiry = kReplyOwedExpiry;

  ContactsStreamState _contactsStream = ContactsStreamState.none;
  Timer? _contactsStreamWatchdog;

  // A contact stream that went silent: scope discovery stays off until the
  // connection is rebuilt.
  bool _scopeSuspended = false;

  // An owed reply expired unanswered: the app can no longer tell which later
  // reply answers which command, so scope discovery stays off until the
  // connection is rebuilt.
  bool _replySyncLost = false;

  // A reboot or reset was written: the radio is going away, so no lease is
  // admitted on this connection object again (a reconnect builds a new one).
  bool _radioRestarting = false;

  // A send to a repeater that is not a saved contact came back
  // ERR_CODE_TABLE_FULL: the connected companion firmware (a bug fixed in
  // v1.17.0's 8 reserved transient slots) needs a contact-table slot for
  // CMD_SEND_ANON_REQ and has none free. Sticky for the life of the
  // connection; a reconnect builds a new instance and clears it.
  bool _scopeCannotAskNonContacts = false;

  // The live lease, its admin-slot token and the gate every other write
  // waits at while it is held.
  ScopeLease? _lease;
  _AdminCommandToken? _leaseToken;
  Completer<void>? _leaseGate;
  int _leaseGateWaiters = 0;
  void Function(Uint8List frame)? _leaseReplyWaiter;

  // The admin slot's owner during the answer wait that follows a lease.
  _AdminCommandToken? _scopeListenToken;
  Completer<Uint8List>? _scopeAnswerCompleter;
  DateTime? _binaryResponseReceivedAt;

  // Bumped by every teardown, so an admission in progress can tell.
  int _scopeEpoch = 0;

  // Completed when scope work lets go of the radio (lease and listen both
  // over); a sign waiting at its entry listens for it.
  Completer<void>? _scopeIdle;
  int _signWaiters = 0;

  /// How long [sign] waits for scope discovery before failing `busy`. Tests
  /// shorten it.
  @visibleForTesting
  Duration signScopeWait = kSignScopeWait;

  late final _ScopeLeaseHostAdapter _scopeHost = _ScopeLeaseHostAdapter(this);

  /// How long an admin command keeps the slot after timing out with its bare
  /// OK still owed. Tests shorten it; nothing in the app passes it.
  final Duration _adminLateResponseBackstop;

  MeshCoreConnection({
    required CompanionTransport transport,
    Duration lateResponseBackstop = const Duration(seconds: 10),
  })  : _transport = transport,
        _adminLateResponseBackstop = lateResponseBackstop {
    _dataSubscription = _transport.dataStream.listen(_onFrameReceived);
  }

  /// Stream of connection step changes
  Stream<ConnectionStep> get stepStream => _stepController.stream;

  /// Stream of channel messages (for RX pings)
  Stream<ChannelMessage> get channelMessageStream =>
      _channelMessageController.stream;

  /// Stream of raw data pushes
  Stream<Map<String, dynamic>> get rawDataStream => _rawDataController.stream;

  /// Stream of LogRxData packets (for unified RX handler)
  Stream<({Uint8List raw, double snr, int rssi})> get logRxDataStream =>
      _logRxDataController.stream;

  /// Stream of ControlData packets (for discovery responses)
  Stream<({Uint8List raw, double snr, int rssi})> get controlDataStream =>
      _controlDataController.stream;

  /// Stream of TraceData packets (for trace path responses)
  /// 0x89 has NO snr/rssi prefix — raw bytes are the trace payload directly
  Stream<Uint8List> get traceDataStream => _traceDataController.stream;

  /// Stream of noise floor updates (dBm)
  Stream<int> get noiseFloorStream => _noiseFloorController.stream;

  /// Stream of battery updates (percentage 0-100)
  Stream<int> get batteryStream => _batteryController.stream;

  /// Stream of PUSH_CODE_PATH_UPDATED pushes (32-byte contact public key).
  Stream<Uint8List> get pathUpdatedStream => _pathUpdatedController.stream;

  /// Current connection step
  ConnectionStep get currentStep => _currentStep;

  /// Device info from query (null if not connected)
  DeviceQueryResponse? get deviceInfo => _deviceInfo;

  /// Matched device model (null if not connected or unknown)
  DeviceModel? get deviceModel => _deviceModel;

  /// Device self info including public key (null if not connected)
  SelfInfo? get selfInfo => _selfInfo;

  /// Device public key as hex string (null if not connected)
  String? get devicePublicKey => _selfInfo?.publicKeyHex;

  /// Last noise floor reading (dBm) or null if not supported/not connected
  int? get lastNoiseFloor => _lastNoiseFloor;

  /// Last battery percentage (0-100) or null if not supported/not connected
  int? get lastBatteryPercent {
    final mv = _lastBatteryMilliVolts;
    return mv != null ? _milliVoltsToPercent(mv) : null;
  }

  /// Wardriving channel info (index, name, secret) - null if not connected
  ChannelInfo? get wardrivingChannel => _wardrivingChannel;

  /// Wardriving channel index (for TX tracking) - null if not connected
  int? get wardrivingChannelIndex => _wardrivingChannel?.channelIndex;

  /// Wardriving channel key (for message decryption) - null if not connected
  Uint8List? get wardrivingChannelKey => _wardrivingChannel?.secret;

  /// Wardriving channel hash (for echo correlation) - null if not connected
  int? get wardrivingChannelHash {
    final channel = _wardrivingChannel;
    return channel != null
        ? CryptoService.computeChannelHash(channel.secret)
        : null;
  }

  void _updateStep(ConnectionStep step) {
    _currentStep = step;
    if (_disposed || _stepController.isClosed) {
      debugLog(
          '[CONN] Ignoring step update on disposed connection (expected during reconnect)');
      return;
    }
    debugLog('[CONN] Step: $step');
    _stepController.add(step);
  }

  /// Execute the full connection workflow
  /// Returns (deviceModel, deviceModelMatched) for display/reporting purposes
  /// Note: This method does NOT modify radio TX power settings - it only reads device info
  Future<({DeviceModel? deviceModel, bool deviceModelMatched})> connect(
      Future<DeviceModel?> Function(String manufacturer)
          resolveDeviceModel) async {
    if (_disposed) {
      throw Exception('Connection instance has been disposed');
    }
    bool deviceModelMatched = false;

    try {
      // Step 1: Transport connect (already connected by caller)
      _updateStep(ConnectionStep.transportConnecting);

      // Step 2: Protocol Handshake (handled automatically by device)
      _updateStep(ConnectionStep.protocolHandshake);
      await Future.delayed(const Duration(milliseconds: 500));

      // Step 3: Device Query
      _updateStep(ConnectionStep.deviceQuery);
      _deviceInfo = await deviceQuery(
          ProtocolConstants.supportedCompanionProtocolVersion);

      // Step 3b: Get Self Info (contains public key)
      // This is critical for geo-auth API authentication
      try {
        _selfInfo = await getSelfInfo();
        final pubKeyHex = _selfInfo?.publicKeyHex;
        if (pubKeyHex == null) {
          throw Exception('getSelfInfo() returned null public key');
        }
        debugLog(
            '[CONN] Public key acquired: ${pubKeyHex.substring(0, 16)}...');
      } catch (e) {
        debugError('[CONN] Failed to get self info (public key): $e');
        // Public key is REQUIRED for geo-auth API
        throw Exception('Failed to acquire device public key: $e');
      }

      // Step 4: Device Identification (match device model for display/reporting purposes)
      // Note: We do NOT modify the radio's TX power - we only read device info
      _updateStep(ConnectionStep.powerConfiguration);
      final deviceInfo = _deviceInfo;
      if (deviceInfo == null) throw Exception('Device query returned null');
      try {
        _deviceModel = await resolveDeviceModel(deviceInfo.manufacturer);
      } catch (error) {
        _deviceModel = null;
        debugWarn('[CONN] Device catalog resolver failed: $error');
      }
      final matchedModel = _deviceModel;
      if (matchedModel != null) {
        deviceModelMatched = true;
        debugLog(
            '[CONN] Device identified: ${matchedModel.shortName} (reports ${matchedModel.power}W / ${matchedModel.txPower}dBm)');
      } else {
        debugLog(
            '[CONN] Device model not recognized - user must manually select power level for reporting');
      }

      // Step 5: Time Sync
      _updateStep(ConnectionStep.timeSync);
      await setDeviceTime(DateTime.now().millisecondsSinceEpoch ~/ 1000);

      // Step 6: API Session Acquisition (geo-auth)
      _updateStep(ConnectionStep.slotAcquisition);
      if (onRequestAuth != null) {
        debugLog('[CONN] Requesting API session via geo-auth');
        final authResult = await onRequestAuth!();
        if (authResult == null || authResult['success'] != true) {
          final reason = authResult?['reason'] ?? 'unknown';
          final message = authResult?['message'] ?? 'Authentication failed';
          debugError(
              '[CONN] API session acquisition failed: $reason - $message');
          // Throw with reason code prefix for proper error handling
          throw Exception('AUTH_FAILED:$reason:$message');
        }
        debugLog(
            '[CONN] API session acquired successfully (session_id: ${authResult['session_id']})');
      } else {
        debugLog(
            '[CONN] No auth callback set, skipping API session acquisition');
      }

      // Guard: transport may have disconnected during the async auth API call
      if (_disposed ||
          _transport.connectionStatus != ConnectionStatus.connected) {
        throw Exception(
            'Transport disconnected during authentication. Please try connecting again.');
      }

      // Step 7: Channel Setup
      _updateStep(ConnectionStep.channelSetup);
      debugLog('[CONN] Creating #wardriving channel');
      _wardrivingChannel = await ChannelService.ensureWardrivingChannel(this);
      debugLog(
          '[CONN] Channel ready: ${_wardrivingChannel?.name ?? 'unknown'} (CH:${_wardrivingChannel?.channelIndex ?? -1})');

      // Step 8: GPS Init (handled externally)
      _updateStep(ConnectionStep.gpsInit);
      // GPS init is handled by GPS service

      // Step 9: Connected
      _updateStep(ConnectionStep.connected);
      debugLog('[CONN] Connection workflow complete');

      // Small delay to avoid BLE command collision
      await Future.delayed(const Duration(milliseconds: 200));

      // Start battery polling (30-second interval)
      _startBatteryPolling();

      // Start noise floor polling (5-second interval)
      // This may fail on older firmware (< v1.11.0)
      _startNoiseFloorPolling();

      return (
        deviceModel: _deviceModel,
        deviceModelMatched: deviceModelMatched
      );
    } catch (e) {
      debugError('[CONN] Connection failed: $e');
      _updateStep(ConnectionStep.error);
      // Clean up BLE connection on failure
      try {
        await _transport.disconnect();
        debugLog('[CONN] Disconnected BLE after connection failure');
      } catch (disconnectError) {
        debugError('[CONN] Failed to disconnect after error: $disconnectError');
      }
      rethrow;
    }
  }

  /// Disconnect and cleanup
  /// Delete wardriving channel early (before stopping services)
  /// This should be called FIRST in the disconnect flow to ensure BLE is still connected
  Future<void> deleteWardrivingChannelEarly() async {
    // Channel deletion is a gated write; a live sign would park it behind the
    // sign timeout while BLE is still up. Abort the sign first.
    _abortPendingSign();
    _abortScopeWork('channel deletion');
    _abortPendingAdmin();
    final channel = _wardrivingChannel;
    if (channel != null) {
      if (channel.name == ChannelService.wardrivingChannelName) {
        await ChannelService.deleteWardrivingChannel(
            this, channel.channelIndex);
      } else {
        // A channel the user saved under their own name with the #wardriving
        // key was reused, not created, so it stays on the radio.
        debugLog('[CHANNEL] Keeping reused channel "${channel.name}" at '
            'index ${channel.channelIndex} (not created by MeshMapper)');
      }
      _wardrivingChannel = null;
    }
  }

  Future<void> disconnect() async {
    try {
      debugLog('[CONN] Disconnecting');
      _abortPendingSign();
      _abortScopeWork('disconnect');
      _abortPendingAdmin();
      _releaseOwnReplies();
      _resetReplyLedger();

      // Stop noise floor polling
      _stopNoiseFloorPolling();

      // Stop battery polling
      _stopBatteryPolling();

      // Channel deletion happens early (before this method is called)
      // See deleteWardrivingChannelEarly() called from app_state_provider

      // Disconnect BLE
      await _transport.disconnect();
      _deviceInfo = null;
      _deviceModel = null;
      _selfInfo = null;
      _lastNoiseFloor = null;
      _lastBatteryMilliVolts = null;
      _updateStep(ConnectionStep.disconnected);
      debugLog('[CONN] Disconnected successfully');
    } catch (e) {
      debugError('[CONN] Disconnect error: $e');
      _updateStep(ConnectionStep.disconnected);
    }
  }

  /// Handle incoming frame from device
  void _onFrameReceived(Uint8List frame) {
    if (frame.isEmpty) return;

    // A RESP_SIGNATURE payload is 64 bytes of Ed25519 signature over the
    // portal's login nonce, and debug logs are uploadable to the bug-report
    // endpoint — so this one frame is logged by length only, never as hex.
    // A CONTACT reply (a contact list stream, a scope lookup) and a new
    // advert push open with a full 32-byte public key, and keys are logged by
    // their 8-hex prefix only: the key past its first 4 bytes is redacted.
    // Every other frame keeps the full hexdump.
    final String frameDump;
    if (frame[0] == ResponseCodes.signature) {
      frameDump = 'SIGNATURE payload redacted';
    } else if ((frame[0] == ResponseCodes.contact ||
            frame[0] == PushCodes.newAdvert) &&
        frame.length > 5) {
      final keyEnd = frame.length < 33 ? frame.length : 33;
      frameDump = '${_hexDump(Uint8List.sublistView(frame, 0, 5))} '
          '[key redacted]'
          '${keyEnd < frame.length ? ' ${_hexDump(Uint8List.sublistView(frame, keyEnd))}' : ''}';
    } else {
      frameDump = _hexDump(frame);
    }

    try {
      final reader = BufferReader(frame);
      final responseCode = reader.readByte();

      // One line per frame, not two. The response code is byte 0 of the dump
      // that follows it, so a separate "Response code:" line repeated the
      // frame's first byte roughly 4,000 times in a five hour session. The
      // per-frame line itself stays: its cadence is the liveness clock that
      // shows when the link or the process went quiet.
      debugLog(
          '[CONN] Frame 0x${responseCode.toRadixString(16).padLeft(2, '0')} '
          '($responseCode), ${frame.length} bytes: $frameDump');

      // The reply ledger sees every frame first. While a lease command
      // awaits its reply, the next reply frame is the lease's, exactly once,
      // before the sign, own-reply, admin and legacy owners are consulted.
      final isReply = _accountReply(responseCode);
      final leaseWaiter = _leaseReplyWaiter;
      if (isReply && responseCode < 0x80 && leaseWaiter != null) {
        _leaseReplyWaiter = null;
        debugLog('[SCOPES] Reply code $responseCode taken by the scope lease');
        leaseWaiter(frame);
        return;
      }

      switch (responseCode) {
        case ResponseCodes.ok:
          {
            debugLog('[CONN] Received OK response');
            // A pending sign owns the bare OK. The write gate keeps every
            // OK-emitting command *issued during* the sign off the wire, but it
            // cannot recall one that was already awaiting its OK when the sign
            // began. That is safe only because the sole other bare-OK consumer
            // is setDeviceTime, which runs once during connect().
            final signOk = _signChunkOkCompleter;
            if (signOk != null) {
              _signChunkOkCompleter = null;
              if (!signOk.isCompleted) signOk.complete();
              break;
            }
            if (_claimOwnReply(null)) break;
            final adminOk = _adminOkCompleter;
            if (adminOk != null) {
              final owner = _adminOkOwner;
              final awaitingLateResponse = _adminOkAwaitingLateResponse;
              _adminOkCompleter = null;
              _adminOkOwner = null;
              _adminOkAwaitingLateResponse = false;
              _cancelAdminLateResponseBackstop();
              if (!adminOk.isCompleted) adminOk.complete();
              if (awaitingLateResponse && owner != null) {
                _endAdminCommand(owner);
              }
              break;
            }
            _setTimeCompleter?.complete();
            _setTimeCompleter = null;
            break;
          }
        case ResponseCodes.err:
          final errorCode =
              reader.remainingBytesCount > 0 ? reader.readByte() : 0;
          debugLog('[CONN] Received ERR response (error code: $errorCode)');
          // A pending sign claims this ERR. Without it the old-firmware feature
          // detect hangs for the full sign timeout.
          //
          // The claim is not airtight, and deliberately so. The write gate
          // keeps every command *issued during* the sign off the wire, but it
          // cannot recall one that was already awaiting its response when the
          // sign began — and unlike the bare OK (whose only other consumer is
          // setDeviceTime, once per connect), ERR has five: stats, channel
          // info, device query, export contact and get time, two of them
          // timer-driven (getStats every 5s, battery every 30s). So a foreign
          // ERR that lands in that window is misattributed to the sign.
          //
          // Bounded, not dangerous: the foreign command still times out on its
          // own (getStats carries its own 5s timeout), and the sign fails and
          // is retried. The one verdict worth protecting is "this firmware has
          // no CMD_SIGN" — the persistence layer requires two strikes before
          // recording it, so a single misattributed ERR cannot condemn a radio
          // that actually supports signing.
          if (_failPendingSign(
            SignException('err',
                'Radio returned ERR during sign (error code $errorCode)'),
            startError: SignException('unsupported',
                'Radio rejected CMD_SIGN_START (error code $errorCode)'),
          )) {
            break;
          }
          if (_claimOwnReply(errorCode)) break;
          // Time sync: error code 6 (ERR_CODE_ILLEGAL_ARG) means "no sync needed" — treat as success
          if (_setTimeCompleter != null) {
            if (errorCode == 6) {
              debugLog(
                  '[CONN] Time sync not needed (error code 6) - treating as success');
            } else {
              debugWarn(
                  '[CONN] Time sync error (code $errorCode) - continuing anyway');
            }
            _setTimeCompleter?.complete();
            _setTimeCompleter = null;
            break;
          }
          // Repeater-admin commands read the code: 2 is "contact unknown",
          // 3 is "table full" on add and "could not send" on login/request.
          // An ERR frame carries no correlation, so claim it for the admin
          // lane only when nothing else is waiting: the noise floor poll runs
          // every 5s and a login can wait up to 60s, and a poller's ERR must
          // not kill that login with the wrong sentence.
          //
          // Scope work holds no untagged command of its own while it owns
          // the slot (a lease command's ERR is taken above, and the answer
          // wait is ended only by its tagged push, a cancel, its timer or a
          // disconnect), so an ERR here belongs to someone else and must not
          // clear the tagged answer the scope listen is waiting for.
          if (!_scopeOwnsSlot &&
              _statsCompleter == null &&
              _channelInfoCompleter == null &&
              _deviceQueryCompleter == null &&
              _exportContactCompleter == null &&
              _getTimeCompleter == null) {
            _failPendingAdmin(RadioErrorException(
                _adminCommandInFlight?.name ?? 'admin', errorCode));
          }
          // Complete any pending completers with error
          final errException = CommandErrorException(errorCode);
          _statsCompleter?.completeError(errException);
          _statsCompleter = null;
          _channelInfoCompleter?.completeError(errException);
          _channelInfoCompleter = null;
          _deviceQueryCompleter?.completeError(errException);
          _deviceQueryCompleter = null;
          _exportContactCompleter?.completeError(errException);
          _exportContactCompleter = null;
          _getTimeCompleter?.completeError(errException);
          _getTimeCompleter = null;
          break;
        case ResponseCodes.deviceInfo:
          _onDeviceInfoResponse(reader);
          break;
        case ResponseCodes.selfInfo:
          _onSelfInfoResponse(reader);
          break;
        case ResponseCodes.sent:
          _onSentResponse(reader);
          break;
        case ResponseCodes.channelMsgRecv:
          _onChannelMsgRecvResponse(reader);
          break;
        case ResponseCodes.channelInfo:
          _onChannelInfoResponse(reader);
          break;
        case PushCodes.rawData:
          _onRawDataPush(reader);
          break;
        case PushCodes.logRxData:
          _onLogRxDataPush(reader);
          break;
        case PushCodes.controlData:
          _onControlDataPush(reader);
          break;
        case PushCodes.traceData:
          _onTraceDataPush(reader);
          break;
        case PushCodes.loginSuccess:
        case PushCodes.loginFail:
          _onLoginPush(responseCode, reader);
          break;
        case PushCodes.binaryResponse:
          _onBinaryResponsePush(reader);
          break;
        case PushCodes.pathUpdated:
          if (reader.remainingBytesCount >= 32 &&
              !_pathUpdatedController.isClosed) {
            final k = reader.readBytes(32);
            debugLog('[CONN] PATH_UPDATED for '
                '${k.sublist(0, 4).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}');
            _pathUpdatedController.add(k);
          }
          break;
        case ResponseCodes.stats:
          _onStatsResponse(reader);
          break;
        case ResponseCodes.batteryVoltage:
          _onBatteryVoltageResponse(reader);
          break;
        case ResponseCodes.currTime:
          if (_getTimeCompleter != null && reader.remainingBytesCount >= 4) {
            _getTimeCompleter?.complete(reader.readUInt32LE());
            _getTimeCompleter = null;
          }
          break;
        case ResponseCodes.exportContact:
          _onExportContactResponse(reader);
          break;
        case ResponseCodes.signStart:
          {
            final completer = _signStartCompleter;
            _signStartCompleter = null;
            if (completer == null || completer.isCompleted) {
              debugLog('[CONN] Ignoring unsolicited SIGN_START response');
              break;
            }
            // [reserved:1][maxSignDataLen:u32 LE]
            if (reader.remainingBytesCount < 5) {
              completer.completeError(const SignException('malformed_response',
                  'SIGN_START response is shorter than 5 bytes'));
              break;
            }
            reader.readByte(); // reserved
            completer.complete(reader.readUInt32LE());
            break;
          }
        case ResponseCodes.signature:
          {
            final completer = _signatureCompleter;
            _signatureCompleter = null;
            if (completer == null || completer.isCompleted) {
              debugLog('[CONN] Ignoring unsolicited SIGNATURE response');
              break;
            }
            // Guard BEFORE readBytes(64): a short frame must fast-fail here,
            // otherwise it becomes a RangeError swallowed by the outer catch
            // and the caller waits out the full 5s timeout for nothing.
            if (reader.remainingBytesCount < 64) {
              completer.completeError(SignException(
                  'malformed_response',
                  'SIGNATURE response carries ${reader.remainingBytesCount} '
                      'bytes, expected 64'));
              break;
            }
            completer.complete(reader.readBytes(64));
            break;
          }
        case ResponseCodes.contactsStart:
          if (_contactsCompleter == null) {
            debugLog('[CONN] Ignoring unsolicited CONTACTS_START');
            break;
          }
          _contactsBuffer = [];
          final count =
              reader.remainingBytesCount >= 4 ? reader.readUInt32LE() : -1;
          debugLog('[CONN] Contact list starting ($count contacts)');
          break;
        case ResponseCodes.contact:
          if (_contactsCompleter == null) break;
          try {
            _contactsBuffer.add(ContactRecord.parse(reader));
          } on FormatException catch (e) {
            debugWarn('[CONN] Skipping malformed contact frame: $e');
          }
          break;
        case ResponseCodes.endOfContacts:
          {
            final completer = _contactsCompleter;
            _contactsCompleter = null;
            final received = _contactsBuffer;
            _contactsBuffer = [];
            // [4][most_recent_lastmod:u32]: the newest lastmod among the
            // contacts just sent, 0 when none were. Only ever moves forward.
            _contactsEndLastmod =
                reader.remainingBytesCount >= 4 ? reader.readUInt32LE() : 0;
            if (completer == null || completer.isCompleted) break;
            for (final c in received) {
              _contactCache[c.publicKeyHex] = c;
            }
            if (_contactsEndLastmod > _contactSince) {
              _contactSince = _contactsEndLastmod;
            }
            final wasPrimed = _contactCachePrimed;
            _contactCachePrimed = true;
            debugLog(wasPrimed
                ? '[CONN] Contact sync: ${received.length} changed, '
                    '${_contactCache.length} cached, since=$_contactSince'
                : '[CONN] Contact list complete (${received.length})');
            completer.complete(List.unmodifiable(_contactCache.values));
            break;
          }
        default:
          // Log unhandled response codes (like JS implementation)
          debugLog(
              '[CONN] Unhandled frame: code=$responseCode (0x${responseCode.toRadixString(16).padLeft(2, '0')})');
          break;
      }
    } catch (e, stack) {
      debugError('[CONN] Error processing frame (${frame.length} bytes): $e');
      debugError('[CONN] Frame hex: $frameDump');
      debugError('[CONN] Stack trace: $stack');
    }
  }

  /// Helper to convert bytes to hex string for debugging
  String _hexDump(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
  }

  /// Complete every pending sign completer with an error. The SIGN_START
  /// completer gets [startError] when supplied, so an ERR at that stage reads
  /// as "this firmware has no CMD_SIGN" rather than a generic failure.
  ///
  /// Returns true when a sign was actually pending, so the caller can treat the
  /// frame as consumed.
  bool _failPendingSign(SignException error, {SignException? startError}) {
    final start = _signStartCompleter;
    final chunk = _signChunkOkCompleter;
    final signature = _signatureCompleter;
    if (start == null && chunk == null && signature == null) return false;

    _signStartCompleter = null;
    _signChunkOkCompleter = null;
    _signatureCompleter = null;

    if (start != null && !start.isCompleted) {
      start.completeError(startError ?? error);
    }
    if (chunk != null && !chunk.isCompleted) chunk.completeError(error);
    if (signature != null && !signature.isCompleted) {
      signature.completeError(error);
    }
    return true;
  }

  /// Claim the single repeater-admin command slot, or throw.
  _AdminCommandToken _beginAdminCommand(String name) {
    if (_disposed) throw StateError('Connection disposed');
    final running = _adminCommandInFlight;
    if (running != null) {
      throw StateError(
          'Repeater admin command ${running.name} is still in flight');
    }
    final token = _AdminCommandToken(name);
    _adminCommandInFlight = token;
    return token;
  }

  void _endAdminCommand(_AdminCommandToken token) {
    if (identical(_adminCommandInFlight, token)) {
      _adminCommandInFlight = null;
    }
  }

  /// Wait for a poll that is already on the wire before an admin frame joins
  /// it.
  ///
  /// [_pollsHeld] only stops poll ticks that START after the slot is claimed.
  /// A getNoiseFloor() already awaiting its answer keeps [_statsCompleter] set
  /// for up to 5s, and an ERR frame carries no correlation: the ERR handler
  /// hands it to that poller, so an admin command's own ERR (addContact's
  /// "table full", say) is eaten and the command times out still holding the
  /// slot. Draining first also keeps a poll reply out of the 52 KB contact
  /// stream, the collision the poll hold was added for.
  ///
  /// Each poll carries its own timeout, so this wait is bounded by theirs.
  /// Their errors belong to the poll, not to the admin command: the settle
  /// futures always complete normally. [kPollDrainTimeout] is the backstop for
  /// a settle future that is somehow never completed: the admin command goes
  /// ahead rather than hanging the sheet on a poll that will never answer.
  Future<void> _drainPollsForAdminCommand(String name) async {
    final pending = <Future<void>>[
      if (_statsRequestSettled case final c?) c.future,
      if (_batteryRequestSettled case final c?) c.future,
    ];
    if (pending.isEmpty) return;
    debugLog('[CONN] $name waiting for ${pending.length} in-flight poll(s)');
    var bounded = false;
    await Future.wait(pending).timeout(
      kPollDrainTimeout,
      onTimeout: () {
        bounded = true;
        return <void>[];
      },
    );
    if (bounded) {
      debugWarn('[CONN] $name: poll drain timed out after '
          '${kPollDrainTimeout.inSeconds}s, proceeding anyway');
      return;
    }
    debugLog('[CONN] $name: pollers drained');
  }

  /// Hand the slot back when the bare OK still owed to [token] never arrives
  /// (the radio dropped the reply, or answered an ERR that went elsewhere).
  ///
  /// Without this the slot stays owned until the sheet closes: every later tap
  /// is refused and both pollers stay held.
  ///
  /// It arms nothing on the way out. A bare OK carries no correlation, so the
  /// lane cannot tell the owed OK from the next command's real one, and
  /// ignoring "the next OK" would cascade: the next command's OK is eaten, it
  /// times out, re-arms the late state, the backstop fires again, and so on.
  /// An OK is never ignored while a command is in flight; one arriving with
  /// nothing pending falls through the handler as it always has.
  void _armAdminLateResponseBackstop(_AdminCommandToken token) {
    _adminLateResponseTimer?.cancel();
    _adminLateResponseTimer = Timer(_adminLateResponseBackstop, () {
      _adminLateResponseTimer = null;
      if (!_adminOkAwaitingLateResponse || !identical(_adminOkOwner, token)) {
        return;
      }
      debugLog('[CONN] Late-response backstop: releasing the admin slot held '
          'by ${token.name} after '
          '${_adminLateResponseBackstop.inSeconds}s with no reply');
      _adminOkCompleter = null;
      _adminOkOwner = null;
      _adminOkAwaitingLateResponse = false;
      _endAdminCommand(token);
    });
  }

  void _cancelAdminLateResponseBackstop() {
    _adminLateResponseTimer?.cancel();
    _adminLateResponseTimer = null;
  }

  /// Complete every pending repeater-admin completer with [error]. Returns
  /// true when at least one was pending.
  bool _failPendingAdmin(Object error) {
    var any = false;
    final lateOkOwner = _adminOkAwaitingLateResponse ? _adminOkOwner : null;
    void fail<T>(Completer<T>? c) {
      if (c != null && !c.isCompleted) {
        c.completeError(error);
        any = true;
      }
    }

    fail(_adminSentCompleter);
    fail(_adminOkCompleter);
    fail(_contactsCompleter);
    fail(_loginCompleter);
    fail(_binaryResponseCompleter);
    _cancelAdminLateResponseBackstop();
    _adminSentCompleter = null;
    _adminOkCompleter = null;
    _adminOkOwner = null;
    _adminOkAwaitingLateResponse = false;
    _contactsCompleter = null;
    _contactsBuffer = [];
    _loginCompleter = null;
    _loginPrefix = null;
    _binaryResponseCompleter = null;
    _binaryResponseTag = null;
    if (lateOkOwner != null) _endAdminCommand(lateOkOwner);
    return any;
  }

  /// Tear down an in-flight repeater-admin command on disconnect/dispose.
  void _abortPendingAdmin() {
    // The slot may belong to scope discovery (its lease or answer wait),
    // which the teardown paths end first through [_abortScopeWork]. An admin
    // abort from anywhere else (the Manage sheet closing) leaves it alone.
    if (_scopeOwnsSlot) {
      debugLog('[CONN] Admin abort skipped: the slot belongs to scope '
          'discovery');
      return;
    }
    final wasPending = _failPendingAdmin(const RadioAbortedException());
    _adminCommandInFlight = null;
    if (wasPending) debugLog('[CONN] Aborted in-flight repeater admin command');
  }

  /// Public for the provider's disconnect sequence (mirrors abortPendingSign).
  void abortPendingAdmin() => _abortPendingAdmin();

  /// Whether the single repeater-admin lane is still owned, including while
  /// an untagged reply is being drained after its caller timed out.
  bool get hasPendingAdminCommand => _adminCommandInFlight != null;

  // ============================================
  // Scope discovery lease
  // ============================================

  /// True while a scope lease holds the radio.
  bool get isScopeLeaseActive => _lease != null;

  /// True while the radio still owes a reply to a command a scope lease
  /// wrote. Replies owed to ordinary traffic (the pollers, a flood scope
  /// write) do not count: the admin lane has always coped with those.
  bool get hasScopeReplyDebt => _repliesOwed.any((e) => e.scopeOwned);

  /// Scope discovery owns the radio: a lease is held, or a reply is still
  /// owed for a command one wrote. What Manage waits for.
  bool get isScopeRadioBusy => _lease != null || hasScopeReplyDebt;

  /// Fired synchronously whenever [isScopeRadioBusy] flips, and only then:
  /// a lease granted or ended, or the last scope-owned reply retired,
  /// expired or cleared. Wired to a plain provider notify so Manage
  /// re-reads the flag the moment the radio frees up.
  void Function()? onScopeRadioBusyChanged;
  bool _scopeRadioBusyReported = false;

  void _reportScopeRadioBusy() {
    final busy = isScopeRadioBusy;
    if (busy == _scopeRadioBusyReported) return;
    _scopeRadioBusyReported = busy;
    debugLog('[SCOPES] Radio ${busy ? 'held' : 'free'} for Manage');
    onScopeRadioBusyChanged?.call();
  }

  /// True during the answer wait that follows a lease (the admin slot is
  /// held by the scope listen).
  bool get isScopeListenActive =>
      _scopeListenToken != null &&
      identical(_adminCommandInFlight, _scopeListenToken);

  /// True once a contact stream went silent, an owed reply expired
  /// unanswered, or a reboot or reset was written; no lease is admitted for
  /// the rest of this connection.
  bool get isScopeDiscoverySuspended =>
      _scopeSuspended || _replySyncLost || _radioRestarting;

  /// True once a send to a repeater that is not a saved contact came back
  /// ERR_CODE_TABLE_FULL: this connection will not ask a non-contact again
  /// until reconnected. A saved contact is unaffected and is still asked
  /// normally.
  bool get scopeCannotAskNonContacts => _scopeCannotAskNonContacts;

  /// Fired once, synchronously, the moment [scopeCannotAskNonContacts] flips
  /// from false to true. Wired to a plain provider notify (the Settings
  /// tile's note), never `mapRevision` (Rule 9).
  void Function()? onScopeCannotAskNonContactsChanged;

  bool get _scopeOwnsSlot {
    final owner = _adminCommandInFlight;
    return owner != null &&
        (identical(owner, _leaseToken) || identical(owner, _scopeListenToken));
  }

  bool get _scopeBusyForSign => _lease != null || isScopeListenActive;

  /// Asks for a short exclusive hold on the radio for one scope request.
  ///
  /// Drains the pollers, then waits up to [admissionWait] (both inside that
  /// one deadline) until the admin slot is free, no sign runs or waits, no
  /// contact stream is open and no reply is owed. The grant is decided in one
  /// synchronous step, which also re-reads [cancel]. Resolves null (with the
  /// reason logged) when it is not admitted in time, [cancel] fires first,
  /// the connection goes away, or scope discovery is suspended.
  Future<ScopeLease?> acquireScopeLease(
      {required Duration admissionWait,
      required ScopeCancelToken cancel}) async {
    final epoch = _scopeEpoch;
    final refused = _scopeHardRefusal(cancel, epoch);
    if (refused != null) {
      debugLog('[SCOPES] Lease not admitted: $refused');
      return null;
    }
    final deadline = Completer<void>();
    final deadlineTimer = Timer(admissionWait, deadline.complete);
    try {
      // The drain alone may run to kPollDrainTimeout; the admission deadline
      // bounds it.
      await Future.any<void>([
        _drainPollsForAdminCommand('scopeLease'),
        deadline.future,
        cancel.whenCancelled,
      ]);
      while (true) {
        final hard = _scopeHardRefusal(cancel, epoch);
        if (hard != null) {
          debugLog('[SCOPES] Lease not admitted: $hard');
          return null;
        }
        final busy = _scopeBusyReason();
        if (busy == null) return _grantScopeLease(cancel);
        if (deadline.isCompleted) {
          debugLog('[SCOPES] Lease not admitted within '
              '${admissionWait.inMilliseconds}ms: $busy');
          return null;
        }
        await Future.any<void>([
          Future<void>.delayed(const Duration(milliseconds: 20)),
          deadline.future,
          cancel.whenCancelled,
        ]);
      }
    } finally {
      deadlineTimer.cancel();
    }
  }

  String? _scopeHardRefusal(ScopeCancelToken cancel, int epoch) {
    if (_disposed) return 'connection disposed';
    if (epoch != _scopeEpoch) return 'connection closed';
    if (cancel.isCancelled) return 'cancelled';
    if (_scopeSuspended) return 'suspended after a silent contact stream';
    if (_replySyncLost) return 'suspended after an owed reply expired';
    if (_radioRestarting) return 'a reboot or reset was sent to the radio';
    return null;
  }

  String? _scopeBusyReason() {
    final owner = _adminCommandInFlight;
    if (owner != null) return 'admin slot held by ${owner.name}';
    if (_signInProgress || _signWaiters > 0) return 'sign in progress';
    if (_contactsStream != ContactsStreamState.none) {
      return 'contact stream ${_contactsStream.name}';
    }
    if (_repliesOwed.isNotEmpty) {
      return '${_repliesOwed.length} repl${_repliesOwed.length == 1 ? 'y' : 'ies'} owed';
    }
    if (_leaseGateWaiters > 0) return 'writes still queued';
    return null;
  }

  ScopeLease _grantScopeLease(ScopeCancelToken cancel) {
    // Never const: each lease needs its own token, compared by identity.
    // ignore: prefer_const_constructors
    final token = _AdminCommandToken('scopeLease');
    _adminCommandInFlight = token;
    _leaseToken = token;
    _leaseGate = Completer<void>();
    final lease = ScopeLease(host: _scopeHost, cancel: cancel);
    _lease = lease;
    debugLog('[SCOPES] Lease granted');
    _reportScopeRadioBusy();
    return lease;
  }

  /// Ends [lease] (see [ScopeLeaseHost.endLease]).
  void _endScopeLease(ScopeLease lease, {required bool listen}) {
    if (!identical(_lease, lease)) return;
    _lease = null;
    _leaseReplyWaiter = null;
    final token = _leaseToken;
    _leaseToken = null;
    if (listen && identical(_adminCommandInFlight, token)) {
      // ignore: prefer_const_constructors
      final listenToken = _AdminCommandToken('scopeListen');
      _scopeListenToken = listenToken;
      _adminCommandInFlight = listenToken;
    } else {
      if (token != null) _endAdminCommand(token);
      _disarmScopeAnswer();
    }
    final gate = _leaseGate;
    _leaseGate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
    debugLog('[SCOPES] Lease released'
        '${listen ? ', waiting for the answer' : ''}'
        '${_repliesOwed.isEmpty ? '' : ' (${_repliesOwed.length} reply owed)'}');
    if (!isScopeListenActive) _notifyScopeIdle();
    _reportScopeRadioBusy();
  }

  /// Ends the answer wait and frees the admin slot.
  void _endScopeListen() {
    _disarmScopeAnswer();
    final token = _scopeListenToken;
    _scopeListenToken = null;
    if (token != null) _endAdminCommand(token);
    if (_lease == null) _notifyScopeIdle();
  }

  Future<ScopeAnswerPush> _armScopeAnswer() {
    final completer = Completer<Uint8List>();
    _scopeAnswerCompleter = completer;
    _binaryResponseCompleter = completer;
    _binaryResponseTag = null;
    return completer.future.then((body) =>
        (body: body, receivedAt: _binaryResponseReceivedAt ?? clock.now()));
  }

  void _disarmScopeAnswer() {
    final completer = _scopeAnswerCompleter;
    if (completer == null) return;
    _scopeAnswerCompleter = null;
    if (identical(_binaryResponseCompleter, completer)) {
      _binaryResponseCompleter = null;
      _binaryResponseTag = null;
    }
  }

  /// Teardown: ends any lease with [ScopeAborted] and any answer wait, and
  /// bumps the epoch so an admission in progress grants nothing.
  void _abortScopeWork(String why) {
    _scopeEpoch++;
    final lease = _lease;
    final listening = isScopeListenActive;
    if (lease == null && !listening) return;
    debugLog('[SCOPES] Scope work aborted ($why)');
    lease?.abortForDisconnect();
    final answer = _scopeAnswerCompleter;
    if (answer != null && !answer.isCompleted) {
      answer.completeError(const RadioAbortedException());
    }
    _endScopeListen();
  }

  Future<void> _waitForScopeIdle(Duration limit) {
    final idle = (_scopeIdle ??= Completer<void>()).future;
    final done = Completer<void>();
    final timer = Timer(limit, () {
      if (!done.isCompleted) done.complete();
    });
    idle.then((_) {
      if (!done.isCompleted) done.complete();
    });
    return done.future.whenComplete(timer.cancel);
  }

  void _notifyScopeIdle() {
    final idle = _scopeIdle;
    _scopeIdle = null;
    if (idle != null && !idle.isCompleted) idle.complete();
  }

  /// Tear down an in-flight sign on disconnect/dispose.
  ///
  /// Releasing the gate here is what keeps disconnect fast: the wardriving
  /// channel deletion is a normal (gated) write, so leaving the gate closed
  /// would park it behind the sign's 5s timeout while the link is dying.
  void _abortPendingSign() {
    final wasPending = _failPendingSign(
        const SignException('aborted', 'Connection closed during sign'));
    final gate = _signGate;
    _signGate = null;
    _signInProgress = false;
    if (gate != null && !gate.isCompleted) gate.complete();
    if (wasPending) debugLog('[CONN] Aborted in-flight sign');
  }

  /// Abort any in-flight sign immediately, releasing the write gate so
  /// teardown-time writes (advert-name restore, path-hash restore, flood
  /// scope, channel deletion) are not parked behind the sign timeout.
  /// Safe to call when no sign is running. The provider calls this FIRST
  /// in its disconnect sequence (wired in a later task).
  void abortPendingSign() => _abortPendingSign();

  void _onDeviceInfoResponse(BufferReader reader) {
    // Protocol format changed in v7/v8:
    // v1-v6: protoVer (1) + manufacturer C-string (64) + publicKey (32)
    // v7+: firmwareVer (1), maxContacts/2 (1), maxChannels (1), BLE PIN (4),
    // buildDate (12), model (40), then optional version and capability fields.
    // Note: Some v7 firmware (e.g., RAK4631) uses the new format

    final firmwareVer = reader.readByte();
    debugLog('[CONN] Firmware version: $firmwareVer');

    if (firmwareVer >= 7) {
      // Protocol v7+ format
      reader.readByte(); // max contacts / 2
      final channelCapacity = reader.readByte();
      final maxChannels = channelCapacity > 0 ? channelCapacity : null;
      reader.readBytes(4); // BLE PIN
      debugLog('[CONN] Channel capacity: ${maxChannels ?? "unknown"}');
      final buildDate = reader.readCString(12); // e.g. "04-Jan-2026"

      // Read manufacturer model as CString(40) — fixed-length null-terminated
      final manufacturerModel = reader.readCString(40);

      // Parse additional fields from v9+ firmware
      int? pathHashMode;
      String? firmwareVersionString;
      if (reader.remainingBytesCount > 0) {
        // FIRMWARE_VERSION: 20-byte null-terminated C-string
        if (reader.remainingBytesCount >= 20) {
          firmwareVersionString = reader.readCString(20);
          debugLog('[CONN] Firmware version string: $firmwareVersionString');
        }

        // client_repeat: 1 byte (v9+, skip)
        if (reader.remainingBytesCount >= 1) {
          reader.readByte(); // client_repeat
        }

        // path_hash_mode: 1 byte (v10+)
        if (reader.remainingBytesCount >= 1) {
          pathHashMode = reader.readByte();
          debugLog(
              '[CONN] Device path hash mode: $pathHashMode (${pathHashMode + 1}-byte hops)');
        }
      }

      debugLog('[CONN] Build date: $buildDate');
      debugLog('[CONN] Manufacturer model: $manufacturerModel');

      final response = DeviceQueryResponse(
        protocolVersion: firmwareVer,
        manufacturer: manufacturerModel,
        maxChannels: maxChannels,
        firmwareBuildDate: buildDate,
        firmwareVersionString: firmwareVersionString,
        pathHashMode: pathHashMode,
      );

      _deviceQueryCompleter?.complete(response);
      _deviceQueryCompleter = null;
    } else {
      // Old protocol v1-v6 format
      final manufacturer = reader.readCString(64);
      reader.readBytes(32); // skip public key

      debugLog('[CONN] Manufacturer: $manufacturer');

      final response = DeviceQueryResponse(
        protocolVersion: firmwareVer,
        manufacturer: manufacturer,
      );

      _deviceQueryCompleter?.complete(response);
      _deviceQueryCompleter = null;
    }
  }

  void _onSelfInfoResponse(BufferReader reader) {
    // SelfInfo response format (from connection.js onSelfInfoResponse):
    // type (1 byte) + txPower (1 byte) + maxTxPower (1 byte) + publicKey (32 bytes)
    // + advLat (4 bytes) + advLon (4 bytes) + reserved (3 bytes) + manualAddContacts (1 byte)
    // + radioFreq (4 bytes) + radioBw (4 bytes) + radioSf (1 byte) + radioCr (1 byte)
    // + name (remaining bytes as string)
    try {
      final type = reader.readByte();
      final txPower = reader.readByte();
      final maxTxPower = reader.readByte();
      final publicKey = reader.readBytes(32);

      // Additional fields added in newer firmware versions, between publicKey and name
      // (MeshCore companion protocol RESP_CODE_SELF_INFO). Older firmware omits this block.
      // Encoding note: the wiki documents radioFreq as uint32 Hz, but real hardware reports
      // it in kHz (a 910.525 MHz radio sends 910525); radioBw is uint32 Hz; SF/CR are bytes.
      int? radioFreqKHz;
      int? radioBwHz;
      int? radioSf;
      int? radioCr;
      if (reader.remainingBytesCount >= 22) {
        reader.readInt32LE(); // advLat
        reader.readInt32LE(); // advLon
        reader.readBytes(3); // reserved
        reader.readByte(); // manualAddContacts
        radioFreqKHz =
            reader.readUInt32LE(); // radioFreq (kHz on real hardware)
        radioBwHz = reader.readUInt32LE(); // radioBw (Hz)
        radioSf = reader.readByte(); // radioSf
        radioCr = reader.readByte(); // radioCr
      }

      // Read name from remaining bytes
      final name = reader.hasMoreBytes ? reader.readString() : '';

      final selfInfo = SelfInfo(
        type: type,
        txPower: txPower,
        maxTxPower: maxTxPower,
        publicKey: publicKey,
        name: name,
        radioFreqKHz: radioFreqKHz,
        radioBwHz: radioBwHz,
        radioSf: radioSf,
        radioCr: radioCr,
      );

      _selfInfo = selfInfo;
      debugLog(
          '[CONN] SelfInfo received: name="${selfInfo.name}", publicKey=${selfInfo.publicKeyHex.substring(0, 16)}..., radio=${selfInfo.radioConfigApi ?? "n/a"}');
      // Raw radio values straight off the device — surfaces the actual encoding in the
      // downloadable debug log (diagnoses any future unit questions).
      debugLog(
          '[CONN] Radio raw: freqKHz=$radioFreqKHz bwHz=$radioBwHz sf=$radioSf cr=$radioCr → ${selfInfo.radioConfigApi ?? "n/a"}');

      _selfInfoCompleter?.complete(selfInfo);
      _selfInfoCompleter = null;
    } catch (e) {
      debugError('[CONN] Error parsing SelfInfo response: $e');
      _selfInfoCompleter?.completeError(e);
      _selfInfoCompleter = null;
    }
  }

  /// RESP_CODE_SENT. The repeater-admin completer wants the parsed
  /// [flood:1][tag:4][est:u32]. Channel messages are answered with OK or ERR
  /// instead (see [_claimOwnReply]).
  void _onSentResponse(BufferReader reader) {
    SentInfo? info;
    if (reader.remainingBytesCount >= 9) {
      final flood = reader.readByte() != 0;
      final tag = reader.readBytes(4);
      final est = reader.readUInt32LE();
      info = SentInfo(flood: flood, tag: tag, estTimeoutMs: est);
    }
    final admin = _adminSentCompleter;
    _adminSentCompleter = null;
    if (admin != null && !admin.isCompleted) {
      if (info == null) {
        admin.completeError(const FormatException(
            'SENT frame carries no tag (shorter than 10 bytes)'));
      } else {
        debugLog('[CONN] SENT flood=${info.flood} '
            'est_timeout=${info.estTimeoutMs}ms');
        admin.complete(info);
      }
    }
  }

  void _onChannelMsgRecvResponse(BufferReader reader) {
    final channelIndex = reader.readByte();
    final senderTimestamp = reader.readUInt32LE();
    final snr = reader.readInt8() / 4.0;
    final rssi = reader.readInt8();
    final text = reader.readString();

    final message = ChannelMessage(
      channelIndex: channelIndex,
      senderTimestamp: senderTimestamp,
      snr: snr,
      rssi: rssi,
      text: text,
    );

    _channelMessageController.add(message);
  }

  void _onChannelInfoResponse(BufferReader reader) {
    final info = ChannelInfo.fromReader(reader);
    final completer = _channelInfoCompleter;
    if (completer == null) {
      debugLog('[CONN] Ignoring unrequested CHANNEL_INFO for slot '
          '${info.channelIndex}');
      return;
    }
    if (info.channelIndex != _channelInfoRequestedIdx) {
      // A late reply to a read that already timed out. Taking it would put
      // every later answer one slot behind its request.
      debugLog('[CONN] Ignoring CHANNEL_INFO for slot ${info.channelIndex} '
          'while waiting for slot $_channelInfoRequestedIdx');
      return;
    }
    completer.complete(info);
    _channelInfoCompleter = null;
    _channelInfoRequestedIdx = null;
  }

  void _onRawDataPush(BufferReader reader) {
    final snr = reader.readInt8() / 4.0;
    final rssi = reader.readInt8();
    reader.readByte(); // reserved
    final payload = reader.readRemainingBytes();

    _rawDataController.add({
      'snr': snr,
      'rssi': rssi,
      'payload': payload,
    });
  }

  void _onLogRxDataPush(BufferReader reader) {
    final snr = reader.readInt8() / 4.0;
    final rssi = reader.readInt8();
    final raw = reader.readRemainingBytes();

    // Broadcast to both legacy stream and new unified RX stream
    _rawDataController.add({
      'snr': snr,
      'rssi': rssi,
      'raw': raw,
    });

    _logRxDataController.add((raw: raw, snr: snr, rssi: rssi));
  }

  void _onControlDataPush(BufferReader reader) {
    final snr = reader.readInt8() / 4.0;
    final rssi = reader.readInt8();
    final raw = reader.readRemainingBytes();

    debugLog('[CONN] Received control data (discovery response): '
        '${raw.length} bytes, snr=$snr, rssi=$rssi');

    _controlDataController.add((raw: raw, snr: snr, rssi: rssi));
  }

  void _onTraceDataPush(BufferReader reader) {
    // 0x89 TraceData has NO snr/rssi prefix (unlike 0x88 LogRxData).
    // The entire remaining payload is the trace response:
    // [reserved][path_len][flags][tag:4][auth:4][path_hashes][path_snrs]
    final raw = reader.readRemainingBytes();

    debugLog('[CONN] Received trace data: ${raw.length} bytes');

    _traceDataController.add(raw);
  }

  void _onLoginPush(int code, BufferReader reader) {
    final completer = _loginCompleter;
    final wanted = _loginPrefix;
    if (completer == null || wanted == null) {
      debugLog('[CONN] Ignoring unsolicited login push');
      return;
    }
    if (reader.remainingBytesCount < 7) {
      debugWarn('[CONN] Login push shorter than 7 bytes, ignoring');
      return;
    }
    final flagByte = reader.readByte();
    final prefix = reader.readBytes(6);
    if (!_areBuffersEqual(prefix, wanted)) {
      debugLog('[CONN] Login push for another contact, ignoring');
      return;
    }
    _loginCompleter = null;
    _loginPrefix = null;
    if (code == PushCodes.loginFail) {
      debugLog('[CONN] LOGIN_FAIL');
      completer.complete(
          LoginResult(success: false, isAdmin: false, prefix: prefix));
      return;
    }
    // [tag:4][acl_perms:1][fw_level:1] follow the prefix on companion
    // firmware v1.9.0 and newer. Anything shorter is unsupported firmware.
    if (reader.remainingBytesCount < 6) {
      debugWarn('[CONN] LOGIN_SUCCESS is ${reader.remainingBytesCount + 7} '
          'bytes; companion firmware older than v1.9.0');
      completer.completeError(const FormatException(
          'LOGIN_SUCCESS shorter than 14 bytes (companion firmware older than v1.9.0)'));
      return;
    }
    reader.readBytes(4); // reply tag
    final aclPerms = reader.readByte();
    final fwLevel = reader.readByte();
    debugLog(
        '[CONN] LOGIN_SUCCESS admin=${flagByte & 1 == 1} fw_level=$fwLevel');
    completer.complete(LoginResult(
      success: true,
      isAdmin: (flagByte & 1) == 1,
      prefix: prefix,
      aclPerms: aclPerms,
      fwLevel: fwLevel,
    ));
  }

  /// [0x8C][reserved:1][tag:4][data]. Only the pending tag completes.
  void _onBinaryResponsePush(BufferReader reader) {
    final completer = _binaryResponseCompleter;
    final wanted = _binaryResponseTag;
    if (completer == null || wanted == null) {
      debugLog('[CONN] Ignoring unsolicited BINARY_RESPONSE');
      return;
    }
    if (reader.remainingBytesCount < 5) {
      debugWarn('[CONN] BINARY_RESPONSE shorter than 5 bytes, ignoring');
      return;
    }
    reader.readByte(); // reserved
    final tag = reader.readBytes(4);
    if (!_areBuffersEqual(tag, wanted)) {
      debugLog('[CONN] BINARY_RESPONSE for another tag, ignoring');
      return;
    }
    _binaryResponseCompleter = null;
    _binaryResponseTag = null;
    _binaryResponseReceivedAt = clock.now();
    final data = reader.readRemainingBytes();
    debugLog('[CONN] BINARY_RESPONSE ${data.length} bytes');
    completer.complete(data);
  }

  void _onStatsResponse(BufferReader reader) {
    // Stats response format (from web client):
    // <stats_type:1> <noise:int16> <last_rssi:int8> <last_snr:int8> <tx_air_secs:uint32> <rx_air_secs:uint32>
    // Valid stats payload is 13 bytes. Some firmware versions send peer info
    // frames on the same response code (0x18) at 82+ bytes — reject those.
    if (reader.remainingBytesCount > 30) {
      _statsCompleter?.complete(0);
      _statsCompleter = null;
      return;
    }
    try {
      final statsType = reader.readByte();
      if (statsType == StatsTypes.radio) {
        final noiseFloor = reader.readInt16LE();
        // Skip remaining fields (lastRssi, lastSnr, txAirSecs, rxAirSecs)
        if (noiseFloor == 0) {
          // MeshCore 1.14.x AGC reset zeroes out noise floor briefly; discard
          debugLog('[CONN] Noise floor reading is 0dBm (AGC reset), ignoring');
          _statsCompleter?.complete(0);
        } else {
          _lastNoiseFloor = noiseFloor;
          _noiseFloorController.add(noiseFloor); // Emit to stream
          debugLog('[CONN] Noise floor updated: ${noiseFloor}dBm');
          _statsCompleter?.complete(noiseFloor);
        }
      } else {
        debugLog('[CONN] Unknown stats type: $statsType');
        _statsCompleter?.complete(0);
      }
      _statsCompleter = null;
    } catch (e) {
      debugError('[CONN] Error parsing stats response: $e');
      _statsCompleter?.completeError(e);
      _statsCompleter = null;
    }
  }

  void _onBatteryVoltageResponse(BufferReader reader) {
    try {
      final milliVolts = reader.readUInt16LE();
      _lastBatteryMilliVolts = milliVolts;
      final percent = _milliVoltsToPercent(milliVolts);

      // Consume any remaining bytes (firmware may send extended format)
      if (reader.remainingBytesCount > 0) {
        final extraBytes = reader.readRemainingBytes();
        // Logged when the count CHANGES, not on every poll. An extended
        // format is normal firmware behaviour, so announcing it twice a
        // minute all session said nothing; a count that shifts mid-session
        // is the part worth seeing, and that still gets a line.
        if (extraBytes.length != _lastBatteryExtraBytes) {
          debugLog('[CONN] Battery response has ${extraBytes.length} extra '
              'bytes (ignoring)');
          _lastBatteryExtraBytes = extraBytes.length;
        }
      } else if (_lastBatteryExtraBytes != 0) {
        debugLog('[CONN] Battery response no longer carries extra bytes');
        _lastBatteryExtraBytes = 0;
      }

      _batteryController.add(percent); // Emit percentage to stream
      debugLog('[CONN] Battery updated: ${milliVolts}mV ($percent%)');
    } catch (e) {
      debugError('[CONN] Error parsing battery response: $e');
    }
  }

  /// Convert battery millivolts to percentage (0-100)
  /// Typical LiPo range: 3.0V (empty) to 4.2V (full)
  int _milliVoltsToPercent(int milliVolts) {
    const minVoltage = 3000; // 3.0V = 0%
    const maxVoltage = 4200; // 4.2V = 100%
    final clamped = milliVolts.clamp(minVoltage, maxVoltage);
    return ((clamped - minVoltage) / (maxVoltage - minVoltage) * 100).round();
  }

  void _onExportContactResponse(BufferReader reader) {
    try {
      final advertPacketBytes = reader.readRemainingBytes();
      final hexString = advertPacketBytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join('');
      final contactUri = 'meshcore://$hexString';

      debugLog(
          '[CONN] Received export contact: ${contactUri.substring(0, 50)}...');

      _exportContactCompleter?.complete(contactUri);
      _exportContactCompleter = null;
    } catch (e) {
      debugError('[CONN] Error parsing export contact response: $e');
      _exportContactCompleter?.completeError(e);
      _exportContactCompleter = null;
    }
  }

  /// The ONE outbound funnel. Every frame this class sends goes through here.
  ///
  /// While a sign is in flight, non-sign frames wait for it to finish. That
  /// matters because CMD_SIGN_DATA is acked with a bare OK (0x00) and so are
  /// setFloodScope, setChannel, setPathHashMode, setAdvertName and setTxPower —
  /// letting one of those onto the wire mid-sign means its OK is consumed as
  /// the chunk ack and the handshake desynchronises. Sign's own frames pass
  /// [isSignFrame] and bypass the gate. [onWire] runs synchronously just
  /// before the frame is handed to the transport, after any gate wait.
  ///
  /// While a scope lease is held, every write not issued by that [lease]
  /// waits at the lease gate the same way, and goes out in order once the
  /// lease is released. A lease write is checked against its lease right
  /// before the transport write, so a cancelled or ended lease never puts
  /// another byte on the air; it then resolves false.
  ///
  /// Every frame that goes out is entered in the reply ledger (see
  /// [_replyShape]) before the transport write starts; the expiry of each
  /// entry starts when that write returns.
  Future<bool> _write(Uint8List bytes,
      {bool isSignFrame = false,
      void Function()? onWire,
      ScopeLease? lease}) async {
    final code = bytes.isNotEmpty ? bytes[0] : -1;
    while (true) {
      if (!isSignFrame) {
        final gate = _signGate;
        if (gate != null && !gate.isCompleted) {
          debugLog('[CONN] Queuing command $code behind an in-progress sign');
          // The gate future NEVER completes with an error, so a queued
          // command is delayed, never failed.
          await gate.future;
          continue;
        }
      }
      if (lease == null) {
        final gate = _leaseGate;
        if (gate != null && !gate.isCompleted) {
          debugLog('[CONN] Queuing command $code behind a scope lease');
          _leaseGateWaiters++;
          try {
            await gate.future;
          } finally {
            _leaseGateWaiters--;
          }
          continue;
        }
      }
      break;
    }
    if (lease != null && (!lease.active || lease.cancelled)) {
      debugLog('[SCOPES] Command $code not written: the lease has ended');
      return false;
    }
    onWire?.call();
    final shape = _replyShape(bytes);
    final owed = <_OwedReply>[
      for (var i = 0; i < shape.replies; i++)
        _OwedReply(code,
            selfTelemetry: shape.selfTelemetry,
            opensContactStream: shape.opensContactStream,
            scopeOwned: lease != null),
    ];
    _repliesOwed.addAll(owed);
    if (shape.replies == 0 && !_radioRestarting) {
      // Reboot, factory reset or a CLI reboot: the radio answers nothing and
      // goes away. No lease until the connection is rebuilt.
      _radioRestarting = true;
      debugWarn('[SCOPES] Command $code restarts the radio; scope discovery '
          'off until reconnect');
    }
    if (shape.opensContactStream) {
      _setContactsStream(ContactsStreamState.requested);
    }
    // APP_START stops the firmware's contact iterator without an END.
    final cancelsStream = code == CommandCodes.appStart &&
        _contactsStream == ContactsStreamState.open;
    try {
      await _transport.write(bytes);
    } catch (_) {
      // CompanionTransport cannot say whether a throwing write went out
      // before it failed, so every throw is ambiguous: the ledger entries
      // stay (and expire as usual) and a contact stream stays requested, so
      // a CONTACTS_START that does arrive opens it, and a stream that never
      // comes trips the silence rule instead of letting a lease in.
      _armReplyExpiry(owed);
      rethrow;
    }
    _armReplyExpiry(owed);
    if (cancelsStream && _contactsStream == ContactsStreamState.open) {
      debugLog('[CONN] APP_START ended the open contact stream');
      _setContactsStream(ContactsStreamState.none);
    }
    return true;
  }

  /// The reply table: how many reply frames [frame] earns. Pure.
  static CommandReplyShape _replyShape(Uint8List frame) {
    if (frame.isEmpty) return const CommandReplyShape();
    final payload = frame.sublist(1);
    bool startsWith(String text) {
      final t = text.codeUnits;
      if (payload.length < t.length) return false;
      for (var i = 0; i < t.length; i++) {
        if (payload[i] != t[i]) return false;
      }
      return true;
    }

    switch (frame[0]) {
      case CommandCodes.getContacts:
        return const CommandReplyShape(opensContactStream: true);
      case CommandCodes.sendTelemetryReq:
        // Only the 4-byte form is the self request, answered by push 0x8B.
        return frame.length == 4
            ? const CommandReplyShape(selfTelemetry: true)
            : const CommandReplyShape();
      case CommandCodes.reboot:
        return startsWith('reboot')
            ? const CommandReplyShape(replies: 0)
            : const CommandReplyShape();
      case CommandCodes.factoryReset:
        return startsWith('reset')
            ? const CommandReplyShape(replies: 0)
            : const CommandReplyShape();
      case CommandCodes.runCliCommand:
        if (frame.length < 3) return const CommandReplyShape();
        final nul = payload.indexOf(0);
        var text =
            String.fromCharCodes(nul < 0 ? payload : payload.sublist(0, nul));
        // The firmware accepts an optional two-character prefix, "xx|".
        if (text.length > 4 && text[2] == '|') text = text.substring(3);
        return text == 'reboot'
            ? const CommandReplyShape(replies: 0)
            : const CommandReplyShape();
      default:
        return const CommandReplyShape();
    }
  }

  /// [_replyShape], for the fixture tests.
  @visibleForTesting
  static CommandReplyShape replyShapeOf(Uint8List frame) => _replyShape(frame);

  /// Writes [frame] as is, through the one funnel. Tests use it for commands
  /// the app has no method for.
  @visibleForTesting
  Future<void> debugWriteRaw(Uint8List frame) => _write(frame);

  /// Replies still owed by the radio, for tests.
  @visibleForTesting
  int get repliesOwedCount => _repliesOwed.length;

  /// Where the contact stream stands, for tests.
  @visibleForTesting
  ContactsStreamState get contactsStreamState => _contactsStream;

  void _armReplyExpiry(List<_OwedReply> owed) {
    for (final entry in owed) {
      if (!_repliesOwed.contains(entry)) continue;
      entry.expiry?.cancel();
      entry.expiry = Timer(replyOwedExpiry, () {
        if (_repliesOwed.remove(entry)) {
          _reportScopeRadioBusy();
          debugLog('[CONN] No reply to command ${entry.command} within '
              '${replyOwedExpiry.inSeconds}s, dropped from the reply ledger');
          // The reply may still come, and nothing says which later frame
          // answers which command: a stale ERR_NOT_FOUND or CONTACT could be
          // taken as a new lookup's answer and skip the zero-hop borrow.
          if (!_replySyncLost) {
            _replySyncLost = true;
            debugWarn('[SCOPES] Replies out of step after command '
                '${entry.command} went unanswered; scope discovery '
                'suspended until reconnect');
          }
        }
      });
    }
  }

  /// Counts [code] against the ledger. Returns true when the frame is a
  /// reply (so a lease waiting on one may take it).
  ///
  /// A reply is any frame below 0x80, plus push 0x8B when the oldest entry is
  /// a self-telemetry request. A streamed CONTACT or END_OF_CONTACTS is never
  /// a reply: it only moves the stream state.
  bool _accountReply(int code) {
    if (code == ResponseCodes.endOfContacts) {
      if (_contactsStream != ContactsStreamState.none) {
        _setContactsStream(ContactsStreamState.none);
      }
      return false;
    }
    if (code == ResponseCodes.contact &&
        _contactsStream != ContactsStreamState.none) {
      _setContactsStream(_contactsStream);
      return false;
    }
    final isReply = code < 0x80 ||
        (code == PushCodes.telemetryResponse &&
            _repliesOwed.isNotEmpty &&
            _repliesOwed.first.selfTelemetry);
    if (!isReply) return false;
    if (code == ResponseCodes.contactsStart &&
        _contactsStream == ContactsStreamState.requested) {
      _setContactsStream(ContactsStreamState.open);
    }
    if (_repliesOwed.isEmpty) return true;
    final entry = _repliesOwed.removeAt(0);
    entry.expiry?.cancel();
    if (entry.scopeOwned) _reportScopeRadioBusy();
    if (entry.opensContactStream &&
        code != ResponseCodes.contactsStart &&
        _contactsStream == ContactsStreamState.requested) {
      // The initial reply was not CONTACTS_START (an ERR such as BAD_STATE):
      // no stream follows.
      _setContactsStream(ContactsStreamState.none);
    }
    return true;
  }

  /// Moves the stream to [state]. Any state but none (re)arms the silence
  /// watchdog, so calling it with the current state marks a frame.
  void _setContactsStream(ContactsStreamState state) {
    _contactsStream = state;
    _contactsStreamWatchdog?.cancel();
    _contactsStreamWatchdog = null;
    if (state == ContactsStreamState.none) return;
    _contactsStreamWatchdog = Timer(kContactsStreamSilence, () {
      _contactsStreamWatchdog = null;
      if (_contactsStream == ContactsStreamState.none || _scopeSuspended) {
        return;
      }
      // A lost START or END, or a frame that never arrived. Not cleared:
      // the firmware may still be streaming, so scope discovery stays off.
      _scopeSuspended = true;
      debugWarn('[SCOPES] Contact stream ${_contactsStream.name} and silent '
          'for ${kContactsStreamSilence.inSeconds}s; scope discovery '
          'suspended until reconnect');
    });
  }

  /// Clears the ledger and the stream state (disconnect and dispose).
  void _resetReplyLedger() {
    for (final entry in _repliesOwed) {
      entry.expiry?.cancel();
    }
    _repliesOwed.clear();
    _reportScopeRadioBusy();
    _contactsStreamWatchdog?.cancel();
    _contactsStreamWatchdog = null;
    _contactsStream = ContactsStreamState.none;
    _scopeSuspended = false;
    _replySyncLost = false;
  }

  /// Queues a claim on the next OK or ERR for a send about to hit the wire.
  _OwnReplyClaim _armOwnReply(_OwnReplyKind kind, {Duration? timeout}) {
    final claim = _OwnReplyClaim(kind);
    final wait = timeout ?? ownReplyTimeout;
    claim.expiry = Timer(wait, () {
      if (_ownReplyClaims.remove(claim)) {
        debugWarn('[CONN] No reply to ${claim.label} within '
            '${wait.inMilliseconds}ms');
      }
      claim.settle();
    });
    _ownReplyClaims.add(claim);
    return claim;
  }

  /// Sends [data] with a claim on its own OK or ERR. The claim is dropped
  /// again when the write itself fails.
  Future<_OwnReplyClaim> _sendClaimingReply(
      BufferWriter data, _OwnReplyKind kind,
      {void Function()? onWire, Duration? timeout}) async {
    _OwnReplyClaim? claim;
    try {
      await _write(data.toBytes(), onWire: () {
        onWire?.call();
        claim = _armOwnReply(kind, timeout: timeout);
      });
    } catch (_) {
      final armed = claim;
      if (armed != null) {
        _ownReplyClaims.remove(armed);
        armed.settle();
      }
      rethrow;
    }
    return claim!;
  }

  /// Hands an OK ([errorCode] null) or an ERR to the oldest pending TX or
  /// discovery claim. Returns false when no claim is pending.
  bool _claimOwnReply(int? errorCode) {
    if (_ownReplyClaims.isEmpty) return false;
    final claim = _ownReplyClaims.removeAt(0);
    claim.answered = true;
    claim.errorCode = errorCode;
    claim.settle();
    if (errorCode == null) {
      debugLog('[CONN] OK claimed by ${claim.label}');
    } else {
      // Logged only for TX and discovery: the send's return and the ping flow
      // are unchanged. A channel write reads the code and throws.
      debugWarn('[CONN] ${switch (claim.kind) {
        _OwnReplyKind.tx => 'TX send',
        _OwnReplyKind.discovery => 'Discovery request',
        _OwnReplyKind.channel => 'Channel write',
      }} rejected by radio (error code $errorCode)');
    }
    return true;
  }

  /// Settles every pending TX or discovery claim, so no send is left waiting
  /// on a link that is going away.
  void _releaseOwnReplies() {
    final claims = List<_OwnReplyClaim>.of(_ownReplyClaims);
    _ownReplyClaims.clear();
    for (final claim in claims) {
      claim.settle();
    }
  }

  /// Write frame to device
  Future<void> _sendToRadio(BufferWriter data) async {
    await _write(data.toBytes());
  }

  /// Completes once an outbound non-sign write would not be parked.
  ///
  /// [_write] queues non-sign frames behind an in-progress sign, and that wait
  /// is deliberately unbounded — a queued command is delayed, never failed.
  /// Signing allows five seconds per protocol phase and the chunk phase loops,
  /// so a caller working to a deadline that simply calls a send method can have
  /// its frame reach the wire long after that deadline, with nothing left to
  /// check by then. Awaiting this first moves the wait to a point where
  /// abandoning is still free and leaves no half-built transmission behind.
  ///
  /// A held scope lease parks writes the same way (for at most its 4 s
  /// deadline), so it is waited out here too.
  Future<void> awaitWritableState() async {
    while (true) {
      final gate = _signGate;
      if (gate != null && !gate.isCompleted) {
        debugLog(
            '[CONN] Caller waiting out an in-progress sign before deciding');
        await gate.future;
        continue;
      }
      final leaseGate = _leaseGate;
      if (leaseGate != null && !leaseGate.isCompleted) {
        debugLog('[CONN] Caller waiting out a scope lease before deciding');
        await leaseGate.future;
        continue;
      }
      return;
    }
  }

  // ============================================
  // Command Methods (ported from connection.js)
  // ============================================

  /// Send AppStart command to request SelfInfo
  /// Reference: sendCommandAppStart() in connection.js
  Future<void> sendCommandAppStart() async {
    final data = BufferWriter();
    data.writeByte(CommandCodes.appStart);
    data.writeByte(1); // appVer
    data.writeBytes(Uint8List(6)); // reserved (6 zero bytes)
    data.writeString('MeshMapper'); // appName
    await _sendToRadio(data);
  }

  /// Get device self info (includes public key)
  /// Reference: getSelfInfo() in connection.js
  Future<SelfInfo> getSelfInfo(
      {Duration timeout = const Duration(seconds: 5)}) async {
    _selfInfoCompleter = Completer<SelfInfo>();

    // Save reference to future BEFORE sending command to avoid race condition
    final future = _selfInfoCompleter!.future;

    // Send AppStart command
    await sendCommandAppStart();

    // Wait for SelfInfo response
    return future.timeout(
      timeout,
      onTimeout: () => throw TimeoutException('getSelfInfo timed out'),
    );
  }

  /// Query device info
  Future<DeviceQueryResponse> deviceQuery(int appTargetVer) async {
    _deviceQueryCompleter = Completer<DeviceQueryResponse>();

    // Save reference to future BEFORE sending command to avoid race condition
    final future = _deviceQueryCompleter!.future;

    final data = BufferWriter();
    data.writeByte(CommandCodes.deviceQuery);
    data.writeByte(appTargetVer);
    await _sendToRadio(data);

    // Send APP_START so device enters companion mode.
    // Without this, some devices won't respond to the device query.
    await sendCommandAppStart();

    return future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException('Device query timed out'),
    );
  }

  /// Set device time and await OK/ERROR response from device
  Future<void> setDeviceTime(int epochSecs) async {
    _setTimeCompleter = Completer<void>();
    final future = _setTimeCompleter!.future;

    final data = BufferWriter();
    data.writeByte(CommandCodes.setDeviceTime);
    data.writeUInt32LE(epochSecs);
    await _sendToRadio(data);

    return future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _setTimeCompleter = null;
        debugWarn('[CONN] Time sync timed out - continuing anyway');
      },
    );
  }

  /// Query the device's current RTC clock (epoch seconds)
  Future<int> getDeviceTime() async {
    _getTimeCompleter = Completer<int>();
    final future = _getTimeCompleter!.future;

    final data = BufferWriter();
    data.writeByte(CommandCodes.getDeviceTime);
    await _sendToRadio(data);

    return future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _getTimeCompleter = null;
        throw TimeoutException('getDeviceTime timed out');
      },
    );
  }

  /// Set TX power
  Future<void> setTxPower(int txPower) async {
    final data = BufferWriter();
    data.writeByte(CommandCodes.setTxPower);
    data.writeByte(txPower);
    await _sendToRadio(data);
  }

  /// Set the companion advertised name
  Future<void> setAdvertName(String name) async {
    final data = BufferWriter();
    data.writeByte(CommandCodes.setAdvertName);
    data.writeString(name);
    await _sendToRadio(data);
  }

  /// Set radio parameters
  Future<void> setRadioParams(int freq, int bw, int sf, int cr) async {
    final data = BufferWriter();
    data.writeByte(CommandCodes.setRadioParams);
    data.writeUInt32LE(freq);
    data.writeUInt32LE(bw);
    data.writeByte(sf);
    data.writeByte(cr);
    await _sendToRadio(data);
  }

  /// Get channel info
  Future<ChannelInfo> getChannel(int channelIdx) async {
    debugLog('[CONN] getChannel($channelIdx) - sending request');
    _channelInfoCompleter = Completer<ChannelInfo>();
    _channelInfoRequestedIdx = channelIdx;

    // Save reference to future BEFORE writing command to avoid race condition
    // where response arrives and nulls completer before we can access the future
    final future = _channelInfoCompleter!.future;

    final data = BufferWriter();
    data.writeByte(CommandCodes.getChannel); // 31 (0x1F)
    data.writeByte(channelIdx);
    final bytes = data.toBytes();
    debugLog(
        '[CONN] getChannel bytes: ${bytes.map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(' ')}');
    await _write(bytes);

    return future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        debugLog('[CONN] getChannel($channelIdx) - TIMEOUT after 5s');
        throw TimeoutException('Get channel timed out');
      },
    );
  }

  /// How long a channel delete waits for its OK during disconnect. Short on
  /// purpose: teardown must not stall on a radio that stays quiet.
  static const Duration channelDeleteReplyTimeout =
      Duration(milliseconds: 1500);

  /// Set channel and await the radio's OK or ERR.
  ///
  /// The firmware answers CMD_SET_CHANNEL with a bare OK, or ERR on a bad
  /// index or name. The reply is claimed like a TX send's (FIFO among own
  /// claims), so an OK arriving for this write is never left for another
  /// consumer. Throws [CommandErrorException] on ERR. When no reply arrives
  /// within [replyTimeout] (default [ownReplyTimeout]) it logs and returns,
  /// as setDeviceTime does: the write may still have landed.
  Future<void> setChannel(int channelIdx, String name, Uint8List secret,
      {Duration? replyTimeout}) async {
    final data = BufferWriter();
    data.writeByte(CommandCodes.setChannel);
    data.writeByte(channelIdx);
    data.writeCString(name, 32);
    data.writeBytes(secret);
    final claim = await _sendClaimingReply(data, _OwnReplyKind.channel,
        timeout: replyTimeout);
    await claim.reply.future;
    final errorCode = claim.errorCode;
    if (errorCode != null) {
      throw CommandErrorException(errorCode);
    }
    if (!claim.answered) {
      debugWarn('[CHANNEL] No OK for channel write at index $channelIdx, '
          'continuing');
    }
  }

  /// Set flood scope for regional packet filtering
  /// TransportKey is 16-byte SHA-256 derived key from scope name
  Future<void> setFloodScope(Uint8List transportKey) async {
    final data = BufferWriter();
    data.writeByte(CommandCodes.setFloodScope);
    data.writeByte(0); // reserved byte
    data.writeBytes(transportKey); // 16-byte key
    await _sendToRadio(data);
  }

  /// Clear flood scope (return to unscoped global flood)
  Future<void> clearFloodScope() async {
    final data = BufferWriter();
    data.writeByte(CommandCodes.setFloodScope);
    data.writeByte(0); // reserved byte — no key means clear
    await _sendToRadio(data);
  }

  /// Delete channel by setting it to empty
  Future<void> deleteChannel(int channelIdx) async {
    await setChannel(channelIdx, '', Uint8List(16),
        replyTimeout: channelDeleteReplyTimeout);
  }

  /// Get all channels (queries until error)
  Future<List<ChannelInfo>> getChannels() async {
    final channels = <ChannelInfo>[];
    var channelIdx = 0;

    while (true) {
      try {
        final channel = await getChannel(channelIdx);
        channels.add(channel);
        channelIdx++;
      } catch (e) {
        // Stop when we get an error (no more channels)
        break;
      }
    }

    return channels;
  }

  /// Find channel by name (exact match)
  Future<ChannelInfo?> findChannelByName(String name) async {
    final channels = await getChannels();
    try {
      return channels.firstWhere((channel) => channel.name == name);
    } catch (e) {
      return null; // Not found
    }
  }

  /// Find channel by secret
  Future<ChannelInfo?> findChannelBySecret(Uint8List secret) async {
    final channels = await getChannels();
    try {
      return channels
          .firstWhere((channel) => _areBuffersEqual(channel.secret, secret));
    } catch (e) {
      return null; // Not found
    }
  }

  /// Helper to compare two byte arrays
  bool _areBuffersEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Send channel text message (for TX pings)
  /// Reference: sendCommandSendChannelTxtMsg in connection.js
  ///
  /// [onWire] runs once the frame is past every write gate (sign, scope
  /// lease), immediately before the transport write.
  Future<void> sendChannelTextMessage(
      int txtType, int channelIdx, int senderTimestamp, String text,
      {void Function()? onWire}) async {
    final data = BufferWriter();
    data.writeByte(CommandCodes.sendChannelTxtMsg);
    data.writeByte(txtType);
    data.writeByte(channelIdx);
    data.writeUInt32LE(senderTimestamp);
    data.writeString(text);

    // The firmware answers with OK, or ERR on a bad channel index, never with
    // RESP_CODE_SENT. Wait for that reply (normally a few milliseconds); the
    // claim gives up after [ownReplyTimeout], as the message may still be sent.
    final claim =
        await _sendClaimingReply(data, _OwnReplyKind.tx, onWire: onWire);
    await claim.reply.future;
  }

  /// Send a pre-composed TX body to the #wardriving channel.
  /// The caller composes the body (privacy wire tag "MM:..." by default, or the
  /// legacy "@[MapperBot] LAT, LON" when the user opts into broadcasting coords)
  /// so the exact same string is used for both TxTracker echo matching and the
  /// actual transmission.
  /// Power is not included in the mesh message — it is sent per-ping in the API payload.
  ///
  /// [onWire] runs when the frame actually goes out, after any wait behind a
  /// sign or a scope lease and before the transport write, so echo tracking
  /// armed there is live for the transmission and timed from it.
  Future<void> sendPing(String message, {void Function()? onWire}) async {
    final channel = _wardrivingChannel;
    if (channel == null) {
      throw Exception('Wardriving channel not initialized');
    }

    debugLog('[CONN] Sending ping: $message');
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await sendChannelTextMessage(
        TxtTypes.plain, channel.channelIndex, timestamp, message,
        onWire: onWire);
  }

  /// Send discovery request to find nearby repeaters/rooms
  /// Reference: MeshCore discovery protocol
  ///
  /// Format:
  /// - Byte 0: CMD_SEND_CONTROL_DATA (0x37)
  /// - Byte 1: flags: DISCOVER_REQ (0x80)
  /// - Byte 2: type filter: REPEATER | ROOM (0x0C)
  /// - Bytes 3-6: random tag (4 bytes)
  /// - Bytes 7-10: timestamp = 0 (discover all)
  ///
  /// Returns the 4-byte tag used for matching responses, and [sentAt]: the
  /// moment the frame was handed to the transport, after any sign or lease
  /// gate wait and before the (acknowledged) transport write. That is local
  /// command submission, not the radio's own transmission.
  Future<({Uint8List tag, DateTime sentAt})> sendDiscoveryRequest() async {
    // Generate random 4-byte tag
    final random = Random.secure();
    final tag = Uint8List.fromList([
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
    ]);

    debugLog('[CONN] Sending discovery request with tag: '
        '${tag.map((b) => b.toRadixString(16).padLeft(2, '0')).join('')}');

    final data = BufferWriter();
    data.writeByte(CommandCodes.sendControlData); // 0x37
    data.writeByte(DiscoveryConstants.discoverReqFlag); // 0x80 = DISCOVER_REQ
    data.writeByte(
        DiscoveryConstants.typeFilterRepeaterRoom); // 0x0C = REPEATER | ROOM
    data.writeBytes(tag); // 4-byte random tag
    data.writeUInt32LE(0); // timestamp = 0 (discover all)
    // Claim the OK or ERR so it cannot complete another command's waiter.
    // Nothing waits on it.
    DateTime? sentAt;
    await _sendClaimingReply(data, _OwnReplyKind.discovery,
        onWire: () => sentAt = clock.now());

    return (tag: tag, sentAt: sentAt ?? clock.now());
  }

  /// Send trace path to a specific repeater (targeted ping / zero-hop trace)
  /// Returns the 4-byte tag used for matching the response
  /// [hopBytes] controls trace ID size: 1, 2, or 4 bytes (bitshift encoding)
  Future<Uint8List> sendTracePath(Uint8List repeaterIdBytes,
      {int hopBytes = 1}) async {
    final random = Random.secure();
    final tag = Uint8List.fromList([
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
    ]);

    // Trace uses bitshift encoding: actual_bytes = 1 << path_sz
    // 1 → path_sz=0, 2 → path_sz=1, 4 → path_sz=2
    final int pathSz;
    switch (hopBytes) {
      case 4:
        pathSz = 2;
        break;
      case 2:
        pathSz = 1;
        break;
      default:
        pathSz = 0;
        break;
    }
    final int flags = pathSz & 0x03;

    debugLog(
        '[CONN] Sending trace to ${repeaterIdBytes.map((b) => b.toRadixString(16).padLeft(2, "0")).join("")} (traceBytes=$hopBytes, path_sz=$pathSz)');

    final data = BufferWriter();
    data.writeByte(CommandCodes.sendTracePath); // 0x24
    data.writeBytes(tag); // 4-byte tag
    data.writeUInt32LE(0); // auth_code = 0
    data.writeByte(flags); // flags with path_sz in bits 0-1
    data.writeBytes(repeaterIdBytes); // target repeater ID
    await _sendToRadio(data);
    return tag;
  }

  /// Get battery voltage
  ///
  /// Fire and forget: RESP_BATTERY_VOLTAGE is pushed and no completer waits on
  /// it, so the in-flight window is the write. That is the window a
  /// repeater-admin frame must not join.
  Future<void> getBatteryVoltage() async {
    final settled = Completer<void>();
    _batteryRequestSettled = settled;
    try {
      final data = BufferWriter();
      data.writeByte(CommandCodes.getBatteryVoltage);
      await _sendToRadio(data);
    } finally {
      if (identical(_batteryRequestSettled, settled)) {
        _batteryRequestSettled = null;
      }
      if (!settled.isCompleted) settled.complete();
    }
  }

  /// Export signed contact URI for API authentication
  /// Returns meshcore:// URI containing signed ADVERT packet
  Future<String> exportContact(
      {Duration timeout = const Duration(seconds: 5)}) async {
    _exportContactCompleter = Completer<String>();
    final future = _exportContactCompleter!.future;

    final data = BufferWriter();
    data.writeByte(CommandCodes.exportContact); // 0x11
    await _sendToRadio(data);

    return future.timeout(
      timeout,
      onTimeout: () => throw TimeoutException('Export contact timed out'),
    );
  }

  /// Read the radio's whole contact list (CMD_GET_CONTACTS with since = 0).
  Future<List<ContactRecord>> getContacts(
      {Duration timeout = const Duration(seconds: 20)}) async {
    final token = _beginAdminCommand('getContacts');
    final completer = Completer<List<ContactRecord>>();
    try {
      await _drainPollsForAdminCommand('getContacts');
      _contactsCompleter = completer;
      // CMD_GET_CONTACTS [4][since:u32]: the firmware sends only contacts
      // with lastmod > since. 0 is the full list, which primes the cache.
      final since = _contactCachePrimed ? _contactSince : 0;
      final data = BufferWriter()
        ..writeByte(CommandCodes.getContacts)
        ..writeUInt32LE(since);
      await _sendToRadio(data);
      return await completer.future.timeout(timeout, onTimeout: () {
        _contactsCompleter = null;
        _contactsBuffer = [];
        throw TimeoutException('getContacts timed out');
      });
    } finally {
      // A write that threw before completer.future was ever awaited leaves
      // this call's completer registered with no listener. Clear it here
      // (only if it is still the one this call installed - a later call may
      // already have replaced it) so a subsequent ERR or _abortPendingAdmin()
      // does not complete it into the void.
      if (identical(_contactsCompleter, completer)) {
        _contactsCompleter = null;
        _contactsBuffer = [];
      }
      _endAdminCommand(token);
    }
  }

  /// Add or update one contact (CMD_ADD_UPDATE_CONTACT). Resolves on OK;
  /// throws [RadioErrorException] (code 3 = table full) on ERR.
  Future<void> addContact(ContactRecord contact,
      {Duration timeout = const Duration(seconds: 5)}) async {
    final token = _beginAdminCommand('addContact');
    final completer = Completer<void>();
    var awaitingLateResponse = false;
    try {
      await _drainPollsForAdminCommand('addContact');
      _adminOkCompleter = completer;
      _adminOkOwner = token;
      _adminOkAwaitingLateResponse = false;
      await _write(contact.toFrame(CommandCodes.addUpdateContact));
      debugLog('[CONN] addContact ${contact.publicKeyHex.substring(0, 8)}');
      await completer.future.timeout(timeout, onTimeout: () {
        if (identical(_adminOkCompleter, completer) &&
            identical(_adminOkOwner, token)) {
          awaitingLateResponse = true;
          _adminOkAwaitingLateResponse = true;
          _armAdminLateResponseBackstop(token);
        }
        throw TimeoutException('addContact timed out');
      });
      // The firmware stamps lastmod from the frame (the phone's clock), which
      // may sit below the radio's newest lastmod and so never come back
      // through a since-sync. Insert it here instead.
      if (_contactCachePrimed) {
        _contactCache[contact.publicKeyHex] = contact;
      }
    } finally {
      // Same orphan-completer guard as getContacts: a write that threw before
      // completer.future was awaited must not leave this call's completer
      // registered for a later ERR or _abortPendingAdmin() to complete
      // unheard.
      if (!awaitingLateResponse &&
          identical(_adminOkCompleter, completer) &&
          identical(_adminOkOwner, token)) {
        _adminOkCompleter = null;
        _adminOkOwner = null;
        _adminOkAwaitingLateResponse = false;
      }
      if (!awaitingLateResponse) _endAdminCommand(token);
    }
  }

  /// CMD_SEND_LOGIN: [26][pubkey:32][password bytes]. The firmware terminates
  /// the frame itself, so no NUL is sent. Resolves with the pushed
  /// LOGIN_SUCCESS / LOGIN_FAIL matched on the 6-byte key prefix.
  ///
  /// The frame is logged by LENGTH only: it carries the admin password and
  /// debug logs ship with bug reports.
  ///
  /// [replyTimeout] turns the radio's est_timeout_ms into the wait for the
  /// push; the session supplies the margin and clamp.
  Future<LoginResult> login(
    Uint8List pubkey,
    String password, {
    Duration sentTimeout = const Duration(seconds: 5),
    Duration Function(int estTimeoutMs) replyTimeout = _defaultReplyTimeout,
  }) async {
    final token = _beginAdminCommand('login');
    final sentCompleter = Completer<SentInfo>();
    final loginCompleter = Completer<LoginResult>();
    try {
      await _drainPollsForAdminCommand('login');
      _adminSentCompleter = sentCompleter;
      // _write parks a non-sign frame behind an in-progress sign's gate for
      // an unbounded wait (see _write), and abortPendingAdmin() can free
      // this call's admin slot (_adminCommandInFlight) for a second login
      // while this one is still parked there. _failPendingAdmin can
      // therefore complete these two completers with an error long before
      // either await below ever runs. Attach a no-op listener to each right
      // away so that error is never left unobserved (an extra listener does
      // not stop the later await from throwing the same error).
      unawaited(sentCompleter.future.then((_) {}, onError: (_) {}));
      _loginCompleter = loginCompleter;
      _loginPrefix = pubkey.sublist(0, 6);
      unawaited(loginCompleter.future.then((_) {}, onError: (_) {}));

      final frame = BufferWriter()
        ..writeByte(CommandCodes.sendLogin)
        ..writeBytes(pubkey)
        ..writeString(password);
      final bytes = frame.toBytes();
      await _write(bytes);
      debugLog('[CONN] Login frame sent (${bytes.length} bytes)');

      final sent =
          await sentCompleter.future.timeout(sentTimeout, onTimeout: () {
        if (identical(_adminSentCompleter, sentCompleter)) {
          _adminSentCompleter = null;
        }
        throw TimeoutException('login: SENT timed out');
      });
      return await loginCompleter.future
          .timeout(replyTimeout(sent.estTimeoutMs), onTimeout: () {
        if (identical(_loginCompleter, loginCompleter)) {
          _loginCompleter = null;
          _loginPrefix = null;
        }
        throw TimeoutException('login: no reply from the repeater');
      });
    } finally {
      // Same orphan-completer guard as getContacts/addContact: while this
      // call was parked behind the sign gate above, an abort can have freed
      // the admin slot for a second login() that has since installed its
      // own completers here. Only clear the fields if they are still the
      // ones this call registered.
      if (identical(_adminSentCompleter, sentCompleter)) {
        _adminSentCompleter = null;
      }
      if (identical(_loginCompleter, loginCompleter)) {
        _loginCompleter = null;
        _loginPrefix = null;
      }
      _endAdminCommand(token);
    }
  }

  static Duration _defaultReplyTimeout(int estTimeoutMs) =>
      Duration(milliseconds: estTimeoutMs) + const Duration(seconds: 5);

  /// CMD_SEND_BINARY_REQ: [50][pubkey:32][request]. Resolves with the
  /// BINARY_RESPONSE data whose tag matches the SENT tag.
  ///
  /// [replyTimeout] turns the radio's est_timeout_ms into the wait for the
  /// response; the session supplies the margin and clamp.
  Future<Uint8List> sendBinaryRequest(
    Uint8List pubkey,
    Uint8List request, {
    Duration sentTimeout = const Duration(seconds: 5),
    Duration Function(int estTimeoutMs) replyTimeout = _defaultReplyTimeout,
  }) async {
    final token = _beginAdminCommand('sendBinaryRequest');
    final sentCompleter = Completer<SentInfo>();
    final responseCompleter = Completer<Uint8List>();
    try {
      await _drainPollsForAdminCommand('sendBinaryRequest');
      _adminSentCompleter = sentCompleter;
      // Same parked-write hazard as login: _write parks a non-sign frame
      // behind an in-progress sign's gate for an unbounded wait (see
      // _write), and _abortPendingAdmin() can free this call's admin slot
      // (_adminCommandInFlight) for a second sendBinaryRequest while this
      // one is still parked there. _failPendingAdmin can therefore complete
      // these two completers with an error long before either await below
      // ever runs. Attach a no-op listener to each right away so that error
      // is never left unobserved.
      unawaited(sentCompleter.future.then((_) {}, onError: (_) {}));
      _binaryResponseCompleter = responseCompleter;
      unawaited(responseCompleter.future.then((_) {}, onError: (_) {}));

      final frame = BufferWriter()
        ..writeByte(CommandCodes.sendBinaryReq)
        ..writeBytes(pubkey)
        ..writeBytes(request);
      await _sendToRadio(frame);
      debugLog(
          '[CONN] Binary request type=${request.isNotEmpty ? request[0] : -1} '
          '(${request.length} bytes) sent');

      final sent =
          await sentCompleter.future.timeout(sentTimeout, onTimeout: () {
        if (identical(_adminSentCompleter, sentCompleter)) {
          _adminSentCompleter = null;
        }
        throw TimeoutException('binary request: SENT timed out');
      });
      // Set after the SENT await resumes. TCP or USB can decode SENT and
      // BINARY_RESPONSE from one read and dispatch them in adjacent stream
      // microtasks, leaving a narrow window where the response arrives before
      // this assignment and is treated as unsolicited. Mesh transit normally
      // leaves seconds between the two frames, so this remains a practical
      // expectation rather than a broader response-buffering change.
      _binaryResponseTag = sent.tag;
      return await responseCompleter.future
          .timeout(replyTimeout(sent.estTimeoutMs), onTimeout: () {
        if (identical(_binaryResponseCompleter, responseCompleter)) {
          _binaryResponseCompleter = null;
          _binaryResponseTag = null;
        }
        throw TimeoutException('binary request: no reply from the repeater');
      });
    } finally {
      // Same orphan-completer guard as login: while this call was parked
      // behind the sign gate above, an abort can have freed the admin slot
      // for a second sendBinaryRequest() that has since installed its own
      // completers here. Only clear the fields if they are still the ones
      // this call registered.
      if (identical(_adminSentCompleter, sentCompleter)) {
        _adminSentCompleter = null;
      }
      if (identical(_binaryResponseCompleter, responseCompleter)) {
        _binaryResponseCompleter = null;
        _binaryResponseTag = null;
      }
      _endAdminCommand(token);
    }
  }

  /// CMD_RESET_PATH: [13][pubkey:32]. The next send to that contact floods.
  Future<void> resetPath(Uint8List pubkey,
      {Duration timeout = const Duration(seconds: 5)}) async {
    final token = _beginAdminCommand('resetPath');
    final completer = Completer<void>();
    var awaitingLateResponse = false;
    try {
      await _drainPollsForAdminCommand('resetPath');
      _adminOkCompleter = completer;
      _adminOkOwner = token;
      _adminOkAwaitingLateResponse = false;
      // Same orphan-completer hazard as login/sendBinaryRequest: attach a
      // no-op listener right away so a _failPendingAdmin error delivered
      // while this call is still parked behind the sign gate (inside
      // _write, below) is never left unobserved.
      unawaited(completer.future.then((_) {}, onError: (_) {}));
      final frame = BufferWriter()
        ..writeByte(CommandCodes.resetPath)
        ..writeBytes(pubkey);
      await _sendToRadio(frame);
      debugLog('[CONN] resetPath '
          '${pubkey.sublist(0, 4).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}');
      await completer.future.timeout(timeout, onTimeout: () {
        if (identical(_adminOkCompleter, completer) &&
            identical(_adminOkOwner, token)) {
          awaitingLateResponse = true;
          _adminOkAwaitingLateResponse = true;
          _armAdminLateResponseBackstop(token);
        }
        throw TimeoutException('resetPath timed out');
      });
      // CMD_RESET_PATH deliberately does not touch lastmod on the radio, so
      // the cleared route would never arrive through a since-sync.
      final hex = pubkey
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join()
          .toUpperCase();
      final cached = _contactCache[hex];
      if (cached != null) {
        _contactCache[hex] = cached.withRouteCleared();
      }
    } finally {
      if (!awaitingLateResponse &&
          identical(_adminOkCompleter, completer) &&
          identical(_adminOkOwner, token)) {
        _adminOkCompleter = null;
        _adminOkOwner = null;
        _adminOkAwaitingLateResponse = false;
      }
      if (!awaitingLateResponse) _endAdminCommand(token);
    }
  }

  /// Ask the radio to Ed25519-sign [data] with its device private key.
  ///
  /// Framing (byte-identical to the portal's meshcore.js, which minted every
  /// existing `portal_pubkeys` row):
  ///   CMD_SIGN_START  (0x21)                    -> RESP_SIGN_START (19)
  ///   CMD_SIGN_DATA   (0x22) + <=128 data bytes -> OK (0x00), one per chunk
  ///   CMD_SIGN_FINISH (0x23)                    -> RESP_SIGNATURE (20) [64]
  ///
  /// Sign the RAW bytes, never their hex text. Throws [SignException] for
  /// protocol failures, [TimeoutException] when the radio goes quiet, and
  /// [StateError] when the connection is disposed or a sign is already running.
  Future<Uint8List> sign(Uint8List data,
      {Duration timeout = const Duration(seconds: 5)}) async {
    if (_disposed) {
      throw StateError('Cannot sign on a disposed connection');
    }
    // A sign's chunk OKs are bare, so it cannot share the radio with a scope
    // lease, and it must not start during the answer wait that follows one.
    // Wait for scope work to let go, then re-check and arm synchronously.
    if (_scopeBusyForSign) {
      _signWaiters++;
      debugLog('[CONN] sign: waiting for scope discovery to release the radio');
      try {
        await _waitForScopeIdle(signScopeWait);
      } finally {
        _signWaiters--;
      }
      if (_disposed) {
        throw StateError('Cannot sign on a disposed connection');
      }
      if (_scopeBusyForSign) {
        debugWarn('[CONN] sign: radio still held by scope discovery after '
            '${signScopeWait.inSeconds}s');
        throw const SignException(
            'busy', 'The radio is busy with scope discovery');
      }
    }
    if (_signInProgress) {
      throw StateError('A sign is already in progress');
    }

    _signInProgress = true;
    final gate = Completer<void>();
    _signGate = gate;
    debugLog('[CONN] sign: starting (${data.length} bytes)');

    try {
      // 1) SIGN_START -> maxSignDataLen
      final startCompleter = Completer<int>();
      _signStartCompleter = startCompleter;
      final startFrame = BufferWriter()..writeByte(CommandCodes.signStart);
      await _write(startFrame.toBytes(), isSignFrame: true);
      final maxSignDataLen = await startCompleter.future.timeout(
        timeout,
        onTimeout: () => throw TimeoutException('sign: SIGN_START timed out'),
      );
      debugLog('[CONN] sign: maxSignDataLen=$maxSignDataLen');

      if (data.length > maxSignDataLen) {
        throw SignException('data_too_long',
            'Payload is ${data.length} bytes, radio accepts $maxSignDataLen');
      }

      // 2) SIGN_DATA chunks, one OK each
      final chunkSize = min(128, maxSignDataLen);
      for (var offset = 0; offset < data.length; offset += chunkSize) {
        final end = min(offset + chunkSize, data.length);
        final okCompleter = Completer<void>();
        _signChunkOkCompleter = okCompleter;
        final chunkFrame = BufferWriter()
          ..writeByte(CommandCodes.signData)
          ..writeBytes(data.sublist(offset, end));
        await _write(chunkFrame.toBytes(), isSignFrame: true);
        await okCompleter.future.timeout(
          timeout,
          onTimeout: () => throw TimeoutException('sign: chunk ack timed out'),
        );
        debugLog('[CONN] sign: chunk acked (${end - offset} bytes)');
      }

      // 3) SIGN_FINISH -> signature
      final sigCompleter = Completer<Uint8List>();
      _signatureCompleter = sigCompleter;
      final finishFrame = BufferWriter()..writeByte(CommandCodes.signFinish);
      await _write(finishFrame.toBytes(), isSignFrame: true);
      final signature = await sigCompleter.future.timeout(
        timeout,
        onTimeout: () => throw TimeoutException('sign: signature timed out'),
      );

      if (signature.length != 64) {
        throw SignException('bad_signature_length',
            'Radio returned ${signature.length} bytes, expected 64');
      }
      debugLog('[CONN] sign: signature received');
      return signature;
    } finally {
      // Clear on EVERY path (success, throw, timeout) or the next sign
      // inherits a stale completer and hangs.
      _signStartCompleter = null;
      _signChunkOkCompleter = null;
      _signatureCompleter = null;
      _signInProgress = false;
      if (identical(_signGate, gate)) _signGate = null;
      if (!gate.isCompleted) gate.complete();
    }
  }

  /// Get radio statistics (noise floor)
  /// Reference: sendCommandGetStats in connection.js
  Future<int> getStats(int statsType) async {
    final completer = Completer<int>();
    _statsCompleter = completer;

    // Save reference to future BEFORE sending command to avoid race condition
    final future = completer.future;

    // A repeater-admin command claiming the slot waits this out before it
    // writes, so its own reply cannot be taken for this one's.
    final settled = Completer<void>();
    _statsRequestSettled = settled;
    try {
      final data = BufferWriter();
      data.writeByte(CommandCodes.getStats);
      data.writeByte(statsType);
      await _sendToRadio(data);

      return await future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          // Clear the slot, or a request the radio never answered keeps
          // _statsCompleter set for the life of the connection and the ERR
          // handler goes on treating the stats poll as pending, which is what
          // decides whether an ERR belongs to the repeater-admin lane.
          if (identical(_statsCompleter, completer)) _statsCompleter = null;
          throw TimeoutException('Get stats timed out');
        },
      );
    } finally {
      // The timeout leg clears the slot itself; this covers the leg it cannot
      // reach, a write that throws. Left set, _statsCompleter stays non-null
      // for the life of the connection and the ERR router keeps handing every
      // ERR to a stats poll that is long gone, so the repeater-admin lane
      // never sees its own. A no-op on the success and timeout legs.
      if (identical(_statsCompleter, completer)) _statsCompleter = null;
      if (identical(_statsRequestSettled, settled)) _statsRequestSettled = null;
      if (!settled.isCompleted) settled.complete();
    }
  }

  /// Get noise floor (convenience method for getStats with Radio type)
  Future<int> getNoiseFloor() async {
    return await getStats(StatsTypes.radio);
  }

  /// Start periodic noise floor polling (5-second interval)
  /// Reference: noiseFloorUpdateTimer in wardrive.js
  void _startNoiseFloorPolling() {
    // Check if firmware supports noise floor (v1.11.0+)
    // For now, we'll try and handle errors gracefully
    _noiseFloorTimer?.cancel();
    _isFetchingNoiseFloor = false;
    _noiseFloorFailCount = 0;
    _noiseFloorBackedOff = false;

    // Get initial reading immediately
    _fetchNoiseFloor();

    _scheduleNoiseFloorTimer(noiseFloorPollInterval);

    debugLog('[CONN] Started noise floor polling '
        '(${noiseFloorPollInterval.inSeconds}s interval)');
  }

  /// Starts noise floor polling outside the connect workflow, for tests.
  @visibleForTesting
  void debugStartNoiseFloorPolling() => _startNoiseFloorPolling();

  /// Whether noise floor polling is running, for tests.
  @visibleForTesting
  bool get isNoiseFloorPolling => _noiseFloorTimer != null;

  /// Whether noise floor polling is backed off to the slower interval.
  @visibleForTesting
  bool get isNoiseFloorBackedOff => _noiseFloorBackedOff;

  void _scheduleNoiseFloorTimer(Duration interval) {
    _noiseFloorTimer?.cancel();
    _noiseFloorTimer = Timer.periodic(interval, (_) async {
      await _fetchNoiseFloor();
    });
  }

  /// True while a repeater admin command holds the link. The two pollers
  /// stand down for it: a 350-contact stream is 52 KB through the
  /// companion's BLE queue, and both times the battery and noise floor
  /// requests landed inside one (2026-09-10) the radio dropped the link.
  /// The poll simply skips a tick; the next one runs once the command ends.
  /// A poll that was ALREADY on the wire when the slot was claimed is waited
  /// out instead, by [_drainPollsForAdminCommand].
  ///
  /// Scope work holds the pollers only while its LEASE is held; during the
  /// answer wait that follows, the slot is owned by a scope-listen token and
  /// the pollers run as normal.
  bool get _pollsHeld =>
      _lease != null ||
      (_adminCommandInFlight != null &&
          !identical(_adminCommandInFlight, _scopeListenToken));

  Future<void> _fetchNoiseFloor() async {
    if (_isFetchingNoiseFloor) return; // Skip if previous fetch still in flight
    if (_pollsHeld) {
      debugLog('[CONN] Noise floor poll skipped: '
          '${_adminCommandInFlight?.name} in flight');
      return;
    }
    _isFetchingNoiseFloor = true;
    // Both checks above, and getStats' claim of the settle slot below, are
    // synchronous, so claiming the admin slot is atomic against this poll: an
    // admin command either sees this request and drains it, or this poll sees
    // the admin slot and skips its tick.
    try {
      // No "fetching" line here on purpose. getNoiseFloor() runs through
      // getStats(), which throws on its own 5 second timeout, so the attempt
      // is recorded either by the value below or by the failure in the catch.
      // An attempt can never go unlogged, which is what made the announcement
      // line (once every 5 seconds, all session) pure duplication.
      await getNoiseFloor();
      _noiseFloorFailCount = 0; // Reset on success
      // Polling may have been stopped (disconnect) while this fetch was in
      // flight; only a live poller returns to the normal interval.
      if (_noiseFloorBackedOff && _noiseFloorTimer != null) {
        _noiseFloorBackedOff = false;
        _scheduleNoiseFloorTimer(noiseFloorPollInterval);
        debugLog('[CONN] Noise floor fetch recovered, polling back to '
            '${noiseFloorPollInterval.inSeconds}s');
      }
    } catch (e) {
      _noiseFloorFailCount++;
      debugLog('[CONN] Noise floor fetch failed '
          '($_noiseFloorFailCount/$_noiseFloorFailLimit): $e');
      // Back off rather than stop: a run of transient failures used to end
      // polling for the rest of the session while battery polls kept working.
      if (_noiseFloorFailCount >= _noiseFloorFailLimit &&
          !_noiseFloorBackedOff &&
          _noiseFloorTimer != null) {
        _noiseFloorBackedOff = true;
        _scheduleNoiseFloorTimer(noiseFloorBackoffInterval);
        debugWarn('[CONN] Noise floor polling slowed to '
            '${noiseFloorBackoffInterval.inSeconds}s after '
            '$_noiseFloorFailLimit consecutive failures');
      }
    } finally {
      _isFetchingNoiseFloor = false;
    }
  }

  /// Stop noise floor polling
  void _stopNoiseFloorPolling() {
    _noiseFloorTimer?.cancel();
    _noiseFloorTimer = null;
    _isFetchingNoiseFloor = false;
    _noiseFloorBackedOff = false;
    debugLog('[CONN] Stopped noise floor polling');
  }

  /// Start periodic battery polling (30-second interval)
  void _startBatteryPolling() {
    _batteryTimer?.cancel();

    // Get initial reading (with error handling)
    _fetchBattery();

    _batteryTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      await _fetchBattery();
    });

    debugLog('[CONN] Started battery polling (30s interval)');
  }

  Future<void> _fetchBattery() async {
    if (_pollsHeld) {
      debugLog('[CONN] Battery poll skipped: '
          '${_adminCommandInFlight?.name} in flight');
      return;
    }
    try {
      debugLog('[CONN] ⚡ Fetching battery voltage (poll triggered)...');
      await getBatteryVoltage();
    } catch (e) {
      debugWarn('[CONN] Battery voltage fetch failed: $e');
      // Don't stop polling - battery might become available
    }
  }

  /// Stop battery polling
  void _stopBatteryPolling() {
    _batteryTimer?.cancel();
    _batteryTimer = null;
    debugLog('[CONN] Stopped battery polling');
  }

  /// Set path hash mode on the radio
  /// mode: 0=1-byte, 1=2-byte, 2=3-byte (persisted in radio prefs)
  Future<void> setPathHashMode(int mode) async {
    final data = BufferWriter();
    data.writeByte(CommandCodes.setPathHashMode); // 61 (0x3D)
    data.writeByte(0); // reserved
    data.writeByte(mode); // 0=1-byte, 1=2-byte, 2=3-byte
    await _sendToRadio(data);
    debugLog('[CONN] Sent setPathHashMode: mode=$mode (${mode + 1}-byte hops)');
  }

  /// Reboot device
  Future<void> reboot() async {
    final data = BufferWriter();
    data.writeByte(CommandCodes.reboot);
    data.writeString('reboot');
    await _sendToRadio(data);
  }

  /// Dispose of resources
  void dispose() {
    _disposed = true;
    _stopNoiseFloorPolling();
    _stopBatteryPolling();
    _abortPendingSign();
    _abortScopeWork('dispose');
    _abortPendingAdmin();
    _releaseOwnReplies();
    _resetReplyLedger();
    _setTimeCompleter = null;
    _dataSubscription?.cancel();
    _stepController.close();
    _channelMessageController.close();
    _rawDataController.close();
    _logRxDataController.close();
    _controlDataController.close();
    _traceDataController.close();
    _noiseFloorController.close();
    _batteryController.close();
    _pathUpdatedController.close();
  }
}

/// Hands a [ScopeLease] the connection's private primitives, so the lease
/// logic can live in its own file without widening this class's API.
class _ScopeLeaseHostAdapter implements ScopeLeaseHost {
  final MeshCoreConnection _c;

  _ScopeLeaseHostAdapter(this._c);

  @override
  bool get repliesSettled => _c._repliesOwed.isEmpty;

  @override
  Future<bool> writeForLease(ScopeLease lease, Uint8List frame) =>
      _c._write(frame, lease: lease);

  @override
  void setLeaseReplyWaiter(
      ScopeLease lease, void Function(Uint8List frame)? waiter) {
    if (identical(_c._lease, lease)) _c._leaseReplyWaiter = waiter;
  }

  @override
  Future<ScopeAnswerPush> armScopeAnswer() => _c._armScopeAnswer();

  @override
  void setScopeAnswerTag(Uint8List tag) {
    if (_c._scopeAnswerCompleter != null) _c._binaryResponseTag = tag;
  }

  @override
  void disarmScopeAnswer() => _c._disarmScopeAnswer();

  @override
  void endLease(ScopeLease lease, {required bool listen}) =>
      _c._endScopeLease(lease, listen: listen);

  @override
  void endListen() => _c._endScopeListen();

  @override
  bool get cannotAskNonContacts => _c._scopeCannotAskNonContacts;

  @override
  void markCannotAskNonContacts() {
    if (_c._scopeCannotAskNonContacts) return;
    _c._scopeCannotAskNonContacts = true;
    debugLog('[SCOPES] Radio contact table full: no more asks to repeaters '
        'that are not saved contacts on this connection');
    _c.onScopeCannotAskNonContactsChanged?.call();
  }
}
