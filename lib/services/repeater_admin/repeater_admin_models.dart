import 'dart:typed_data';

import '../../models/repeater.dart';
import '../../utils/public_key.dart';
import '../meshcore/buffer_utils.dart';
import '../meshcore/protocol_constants.dart';

/// Page size used for one neighbour-table request (entries per page).
const int kNeighbourPageSize = 10;

/// Prefix length, in bytes, used when requesting the neighbour table.
const int kNeighbourPrefixLen = 8;

/// Hard cap on how many neighbour-table pages a session will fetch, so a
/// stuck or oversized table cannot loop forever.
const int kNeighbourMaxPages = 30;

/// Cap on how many neighbour rows are ever uploaded for one repeater.
const int kNeighbourUploadCap = 300;

/// Decodes a hex string into bytes. Case-insensitive. Throws
/// [FormatException] when [hex] has an odd length or a non-hex character.
Uint8List hexToBytes(String hex) {
  if (hex.length.isOdd) {
    throw FormatException('Odd length hex string: $hex');
  }
  final bytes = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    final byteHex = hex.substring(i * 2, i * 2 + 2);
    final value = int.tryParse(byteHex, radix: 16);
    if (value == null) {
      throw FormatException('Invalid hex character in: $byteHex');
    }
    bytes[i] = value;
  }
  return bytes;
}

/// Encodes [bytes] as an upper case hex string, two characters per byte.
String bytesToHex(List<int> bytes) {
  final buffer = StringBuffer();
  for (final b in bytes) {
    buffer.write(b.toRadixString(16).padLeft(2, '0').toUpperCase());
  }
  return buffer.toString();
}

/// A repeater the admin flow is targeting, identified by its full public
/// key. The key is always held normalized (upper case, 64 hex characters).
class RepeaterTarget {
  /// The normalized upper case 64-hex public key.
  final String hexId;

  /// Display name of the repeater.
  final String name;

  /// Latitude of the repeater.
  final double lat;

  /// Longitude of the repeater.
  final double lon;

  /// Builds a target from an already-known key, name and location. Throws
  /// [ArgumentError] when [hexId] does not normalize to a full public key.
  RepeaterTarget({
    required String hexId,
    required this.name,
    required this.lat,
    required this.lon,
  }) : hexId = normalizePublicKey(hexId) ??
            (throw ArgumentError.value(hexId, 'hexId', 'not a full public key'));

  /// Builds a target from a [Repeater] loaded from the API. Throws
  /// [ArgumentError] when the repeater's `hexId` is not a full public key.
  factory RepeaterTarget.fromRepeater(Repeater r) {
    return RepeaterTarget(hexId: r.hexId, name: r.name, lat: r.lat, lon: r.lon);
  }

  /// The 32-byte public key.
  Uint8List get publicKey => hexToBytes(hexId);

  /// The first 8 hex characters of the key, used as a short display id.
  String get shortId => hexId.substring(0, 8);
}

/// A route to a repeater, decoded from the radio's route-hop bytes: either a
/// learned sequence of hop hashes or the flood fallback (no route learned).
class RepeaterRoute {
  /// The route's hop hashes, each an upper case hex string.
  final List<String> hops;

  /// True when this route is the flood fallback rather than a learned path.
  final bool flood;

  /// Builds a route from an already-decoded hop list.
  const RepeaterRoute({required this.hops, required this.flood});

  /// The flood (no learned route) route.
  const RepeaterRoute.flood()
      : hops = const [],
        flood = true;

  /// Decodes [bytes] into a route. Empty bytes is flood. When the length
  /// does not divide evenly by [hopBytes] (or [hopBytes] is less than 1),
  /// falls back to splitting into one-byte hops.
  factory RepeaterRoute.fromRouteBytes(Uint8List bytes, {required int hopBytes}) {
    if (bytes.isEmpty) {
      return const RepeaterRoute.flood();
    }
    var width = hopBytes;
    if (width < 1 || bytes.length % width != 0) {
      width = 1;
    }
    final hops = <String>[];
    for (var i = 0; i < bytes.length; i += width) {
      hops.add(bytesToHex(bytes.sublist(i, i + width)));
    }
    return RepeaterRoute(hops: hops, flood: false);
  }

  /// Describes the route as human-readable text: `'Flood (no route learned
  /// yet)'` when flooded or empty, otherwise each hop resolved via [nameFor]
  /// (falling back to its hex when unresolved) joined with `' > '`.
  String describe(String? Function(String hopHex) nameFor) {
    if (flood || hops.isEmpty) {
      return 'Flood (no route learned yet)';
    }
    return hops.map((h) => nameFor(h) ?? h).join(' > ');
  }
}

/// The evidence gathered that the app is actually logged in as admin on a
/// repeater, built into the wire shape the claim endpoint expects.
class AdminProof {
  /// True when the login handshake reported an admin role.
  final bool loginAdmin;

  /// True when an access-list response was received and checked.
  final bool aclConfirmed;

  /// The permission bits found for the app's own access-list entry.
  final int? aclPerms;

  /// The repeater's reported firmware level, when known.
  final int? fwLevel;

  /// How many access-list entries were parsed.
  final int aclEntries;

  /// True when the app's own access-list entry carries admin permissions.
  final bool ownEntryIsAdmin;

  /// Builds a proof from its component facts.
  const AdminProof({
    required this.loginAdmin,
    required this.aclConfirmed,
    this.aclPerms,
    this.fwLevel,
    required this.aclEntries,
    required this.ownEntryIsAdmin,
  });

  /// True when both the login and the access list agree the app is admin.
  bool get isProven => loginAdmin && aclConfirmed;

  /// The wire shape of this proof, as sent with a repeater claim.
  Map<String, dynamic> toWire() => {
        'login': loginAdmin ? 'admin' : 'guest',
        'acl': aclConfirmed,
        'perms': aclPerms ?? 0,
        'fw_level': fwLevel,
      };
}

/// One entry in a repeater's access control list.
class AccessEntry {
  /// The 6-byte public key prefix identifying the entry's owner.
  final Uint8List prefix;

  /// The entry's permission bits.
  final int perms;

  /// Builds an access list entry from its prefix and permission byte.
  const AccessEntry({required this.prefix, required this.perms});

  /// True when the low two permission bits are both set (PERM_ACL_ADMIN).
  bool get isAdmin => (perms & 3) == 3;
}

/// A repeater's access control list, as returned by a GET_ACCESS_LIST
/// request.
class AccessList {
  /// The repeater's own clock, seconds since epoch, at the time it answered.
  final int senderTs;

  /// The parsed entries.
  final List<AccessEntry> entries;

  /// Builds an access list from its header and entries.
  const AccessList({required this.senderTs, required this.entries});
}

/// Parses a GET_ACCESS_LIST response. Throws [FormatException] when [data]
/// is shorter than the 4-byte header. Reads 7-byte entries (6-byte prefix
/// plus 1 permission byte) until fewer than 7 bytes remain; a trailing
/// partial entry is ignored.
AccessList parseAccessList(Uint8List data) {
  if (data.length < 4) {
    throw FormatException('Access list response too short: ${data.length} bytes');
  }
  final reader = BufferReader(data);
  final senderTs = reader.readUInt32LE();
  final entries = <AccessEntry>[];
  while (reader.remainingBytesCount >= 7) {
    final prefix = reader.readBytes(6);
    final perms = reader.readByte();
    entries.add(AccessEntry(prefix: prefix, perms: perms));
  }
  return AccessList(senderTs: senderTs, entries: entries);
}

/// Builds the GET_ACCESS_LIST request bytes.
Uint8List buildAccessListRequest() {
  return Uint8List.fromList([BinaryReqTypes.getAccessList, 0, 0]);
}

/// One row of a repeater's neighbour table.
class RepeaterNeighbour {
  /// Upper case hex prefix of the neighbour's public key.
  final String prefixHex;

  /// Seconds since the repeater last heard this neighbour.
  final int heardSecsAgo;

  /// Signal-to-noise ratio, in dB, for the last time it was heard.
  final double snrDb;

  /// A resolved display name for the neighbour, when known.
  final String? name;

  /// Builds a neighbour row.
  const RepeaterNeighbour({
    required this.prefixHex,
    required this.heardSecsAgo,
    required this.snrDb,
    this.name,
  });

  /// Returns a copy of this row with [name] applied.
  RepeaterNeighbour withName(String? name) => RepeaterNeighbour(
        prefixHex: prefixHex,
        heardSecsAgo: heardSecsAgo,
        snrDb: snrDb,
        name: name,
      );

  /// The wire shape of this row, as uploaded with a repeater claim.
  Map<String, dynamic> toWire() => {
        'prefix': prefixHex,
        'snr': snrDb,
        'heard_secs_ago': heardSecsAgo,
      };
}

/// One page of a repeater's neighbour table, as returned by a
/// GET_NEIGHBOURS request.
class NeighbourPage {
  /// The repeater's own clock, seconds since epoch, at the time it answered.
  final int senderTs;

  /// The total number of neighbours the repeater knows about.
  final int total;

  /// How many entries this page actually returned.
  final int returned;

  /// The parsed neighbour rows.
  final List<RepeaterNeighbour> entries;

  /// Builds a neighbour page from its header and entries.
  const NeighbourPage({
    required this.senderTs,
    required this.total,
    required this.returned,
    required this.entries,
  });
}

/// Parses a GET_NEIGHBOURS response. Throws [FormatException] when [data]
/// is shorter than the 8-byte header. Reads up to `returned` entries of
/// `[prefix:prefixLen][heard_secs_ago:u32][snr:i8]`, stopping at the first
/// incomplete entry (ignored). `snrDb` is the signed SNR byte divided by 4.
NeighbourPage parseNeighbourPage(Uint8List data, {required int prefixLen}) {
  if (data.length < 8) {
    throw FormatException('Neighbour page response too short: ${data.length} bytes');
  }
  final reader = BufferReader(data);
  final senderTs = reader.readUInt32LE();
  final total = reader.readUInt16LE();
  final returned = reader.readUInt16LE();
  final entries = <RepeaterNeighbour>[];
  final entryLen = prefixLen + 5;
  while (entries.length < returned && reader.remainingBytesCount >= entryLen) {
    final prefix = reader.readBytes(prefixLen);
    final heardSecsAgo = reader.readUInt32LE();
    final snr = reader.readInt8();
    entries.add(RepeaterNeighbour(
      prefixHex: bytesToHex(prefix),
      heardSecsAgo: heardSecsAgo,
      snrDb: snr / 4.0,
    ));
  }
  return NeighbourPage(senderTs: senderTs, total: total, returned: returned, entries: entries);
}

/// Builds a GET_NEIGHBOURS request: type, version (0), count, offset
/// (u16 LE), order (0, newest first), prefix length, random tag (u32 LE).
/// Always 11 bytes.
Uint8List buildNeighbourRequest({
  required int offset,
  required int random,
  int count = kNeighbourPageSize,
  int prefixLen = kNeighbourPrefixLen,
}) {
  final writer = BufferWriter();
  writer.writeByte(BinaryReqTypes.getNeighbours);
  writer.writeByte(0); // version
  writer.writeByte(count);
  writer.writeUInt16LE(offset);
  writer.writeByte(0); // order: newest first
  writer.writeByte(prefixLen);
  writer.writeUInt32LE(random);
  return writer.toBytes();
}

/// A repeater claim to (or from) the MeshMapper server: a repeater bound to
/// this account with proof of admin access.
class RepeaterClaim {
  /// Upper case 64-hex public key of the claimed repeater.
  final String repeaterHex;

  /// Display name of the repeater.
  final String name;

  /// IATA zone code, when known.
  final String? iata;

  /// When the claim was made, Unix seconds.
  final int claimedAt;

  /// When the claim was last updated, Unix seconds.
  final int updatedAt;

  /// Builds a claim from its component fields.
  const RepeaterClaim({
    required this.repeaterHex,
    required this.name,
    this.iata,
    required this.claimedAt,
    required this.updatedAt,
  });

  /// Parses a claim from JSON. Throws [FormatException] when neither
  /// `repeater` nor `repeater_hex` normalizes to a full public key.
  factory RepeaterClaim.fromJson(Map<String, dynamic> json) {
    final rawKey = json['repeater'] as String? ?? json['repeater_hex'] as String?;
    final key = normalizePublicKey(rawKey);
    if (key == null) {
      throw FormatException('Invalid repeater key in claim JSON: $rawKey');
    }
    return RepeaterClaim(
      repeaterHex: key,
      name: json['name'] as String? ?? '',
      iata: json['iata'] as String?,
      claimedAt: _asInt(json['claimed_at']),
      updatedAt: _asInt(json['updated_at']),
    );
  }

  /// Parses a claim from JSON, returning null instead of throwing when the
  /// key is missing or invalid.
  static RepeaterClaim? tryFromJson(Map<String, dynamic> json) {
    try {
      return RepeaterClaim.fromJson(json);
    } on FormatException {
      return null;
    }
  }

  /// The JSON shape of this claim.
  Map<String, dynamic> toJson() => {
        'repeater': repeaterHex,
        'name': name,
        'iata': iata,
        'claimed_at': claimedAt,
        'updated_at': updatedAt,
      };
}

int _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

/// Thrown when a repeater admin operation cannot proceed, carrying a plain
/// sentence describing why.
class RepeaterAdminFailure implements Exception {
  /// A plain sentence describing the failure.
  final String message;

  /// Builds a failure with [message].
  const RepeaterAdminFailure(this.message);

  @override
  String toString() => 'RepeaterAdminFailure: $message';
}
