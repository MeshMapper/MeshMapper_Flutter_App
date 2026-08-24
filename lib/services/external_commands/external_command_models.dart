import 'package:flutter/foundation.dart';

enum ExternalCommandSource {
  watch,
  siri;

  static ExternalCommandSource? fromWire(String value) {
    for (final source in values) {
      if (source.name == value) return source;
    }
    return null;
  }
}

enum ExternalSessionCommandKind {
  startSession,
  stopSession,
  manualPing;

  static ExternalSessionCommandKind? fromWire(String value) {
    for (final kind in values) {
      if (kind.name == value) return kind;
    }
    return null;
  }
}

/// The generic session modes an external surface may request.
///
/// Trace is intentionally absent: it needs a stable repeater identity and a
/// dedicated command rather than a string smuggled through generic Start.
enum ExternalSessionMode {
  active,
  passive,
  hybrid;

  static ExternalSessionMode? fromWire(String value) {
    for (final mode in values) {
      if (mode.name == value) return mode;
    }
    return null;
  }

  String get displayName => switch (this) {
        ExternalSessionMode.active => 'Active',
        ExternalSessionMode.passive => 'Passive Discovery',
        ExternalSessionMode.hybrid => 'Hybrid',
      };
}

enum ExternalCommandDisposition {
  admitted,
  noOp,
  refused;
}

@immutable
class ExternalSessionCommand {
  const ExternalSessionCommand({
    required this.id,
    required this.source,
    required this.kind,
    required this.issuedAt,
    this.mode,
    this.sessionId,
  });

  final String id;
  final ExternalCommandSource source;
  final ExternalSessionCommandKind kind;
  final DateTime issuedAt;
  final String? mode;
  final String? sessionId;

  static ExternalSessionCommand? fromMap(
    Map<Object?, Object?> map, {
    required ExternalCommandSource expectedSource,
  }) {
    final id = map['id'];
    final source = map['source'];
    final kind = map['kind'];
    final issuedAtMs = map['issuedAtMs'];
    if (id is! String ||
        id.isEmpty ||
        source is! String ||
        ExternalCommandSource.fromWire(source) != expectedSource ||
        kind is! String ||
        issuedAtMs is! num) {
      return null;
    }
    final parsedKind = ExternalSessionCommandKind.fromWire(kind);
    if (parsedKind == null) return null;
    final mode = map['mode'];
    final sessionId = map['sessionId'];
    if (mode != null && mode is! String) return null;
    if (sessionId != null && sessionId is! String) return null;

    return ExternalSessionCommand(
      id: id,
      source: expectedSource,
      kind: parsedKind,
      issuedAt: DateTime.fromMillisecondsSinceEpoch(issuedAtMs.toInt()),
      mode: mode as String?,
      sessionId: sessionId as String?,
    );
  }
}

@immutable
class ExternalCommandAdmission {
  const ExternalCommandAdmission({
    required this.disposition,
    this.reason,
    this.mode,
  });

  final ExternalCommandDisposition disposition;
  final String? reason;
  final ExternalSessionMode? mode;

  bool get shouldExecute => disposition == ExternalCommandDisposition.admitted;
}

@immutable
class ExternalCommandCompletion {
  const ExternalCommandCompletion({
    required this.success,
    required this.disposition,
    this.message,
    this.sessionId,
    this.mode,
  });

  final bool success;
  final ExternalCommandDisposition disposition;
  final String? message;
  final String? sessionId;
  final ExternalSessionMode? mode;

  Map<String, Object?> toMap({String? commandId}) => {
        if (commandId != null) 'id': commandId,
        'success': success,
        'disposition': disposition.name,
        'message': message,
        'sessionId': sessionId,
        'mode': mode?.name,
      };
}
