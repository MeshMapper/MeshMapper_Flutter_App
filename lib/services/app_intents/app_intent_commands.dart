import '../external_commands/external_command_models.dart';

enum AppIntentCommandKind {
  startSession,
  stopSession,
  manualPing,
  connectLastCompanion;

  static AppIntentCommandKind? fromWire(String value) {
    for (final kind in values) {
      if (kind.name == value) return kind;
    }
    return null;
  }

  ExternalSessionCommandKind? get sessionKind => switch (this) {
        AppIntentCommandKind.startSession =>
          ExternalSessionCommandKind.startSession,
        AppIntentCommandKind.stopSession =>
          ExternalSessionCommandKind.stopSession,
        AppIntentCommandKind.manualPing =>
          ExternalSessionCommandKind.manualPing,
        AppIntentCommandKind.connectLastCompanion => null,
      };
}

/// A mutation arriving from the iOS App Intents transport.
///
/// Session mutations convert to [ExternalSessionCommand] so Siri and Watch
/// retain one policy path. Connecting is intentionally Siri-only and remains
/// outside that session model.
class AppIntentCommand {
  const AppIntentCommand({
    required this.id,
    required this.kind,
    required this.issuedAt,
    this.expiresAt,
    this.mode,
    this.sessionId,
  });

  final String id;
  final AppIntentCommandKind kind;
  final DateTime issuedAt;

  /// When the App Intent stops waiting and reports failure to the person.
  ///
  /// Older native builds omit it; the shared age rule still bounds those.
  final DateTime? expiresAt;
  final String? mode;
  final String? sessionId;

  static AppIntentCommand? fromMap(Map<Object?, Object?> map) {
    final id = map['id'];
    final source = map['source'];
    final kind = map['kind'];
    final issuedAtMs = map['issuedAtMs'];
    if (id is! String ||
        id.isEmpty ||
        source != ExternalCommandSource.siri.name ||
        kind is! String ||
        issuedAtMs is! num) {
      return null;
    }
    final parsedKind = AppIntentCommandKind.fromWire(kind);
    if (parsedKind == null) return null;
    final mode = map['mode'];
    final sessionId = map['sessionId'];
    final expiresAtMs = map['expiresAtMs'];
    if (mode != null && mode is! String) return null;
    if (sessionId != null && sessionId is! String) return null;
    if (expiresAtMs != null && expiresAtMs is! num) return null;

    return AppIntentCommand(
      id: id,
      kind: parsedKind,
      issuedAt: DateTime.fromMillisecondsSinceEpoch(issuedAtMs.toInt()),
      expiresAt: expiresAtMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              (expiresAtMs as num).toInt(),
            ),
      mode: mode as String?,
      sessionId: sessionId as String?,
    );
  }

  ExternalSessionCommand? toExternalSessionCommand() {
    final sessionKind = kind.sessionKind;
    if (sessionKind == null) return null;
    return ExternalSessionCommand(
      id: id,
      source: ExternalCommandSource.siri,
      kind: sessionKind,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      mode: mode,
      sessionId: sessionId,
    );
  }
}
