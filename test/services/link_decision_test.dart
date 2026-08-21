import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/link_decision.dart';

/// The "strictly non-fatal" contract in table form. Exactly ONE combination
/// prompts; every other row is a silent skip.
void main() {
  const goodPubkey =
      'AABBCCDDEEFF00112233445566778899AABBCCDDEEFF001122334455667788AA';

  LinkFlowDecision call({
    bool loggedIn = true,
    bool offlineMode = false,
    bool anonymousMode = false,
    bool autoPingActive = false,
    bool autoReconnecting = false,
    String? pubkey = goodPubkey,
    bool declined = false,
    bool linked = false,
    bool signUnsupported = false,
    bool promptedThisAppSession = false,
  }) =>
      decideLinkFlow(
        loggedIn: loggedIn,
        offlineMode: offlineMode,
        anonymousMode: anonymousMode,
        autoPingActive: autoPingActive,
        autoReconnecting: autoReconnecting,
        pubkey: pubkey,
        declined: declined,
        linked: linked,
        signUnsupported: signUnsupported,
        promptedThisAppSession: promptedThisAppSession,
      );

  test('the all-clear row prompts', () {
    expect(call(), LinkFlowDecision.prompt);
  });

  final skipRows = <String, LinkFlowDecision Function()>{
    'not signed in': () => call(loggedIn: false),
    'offline mode': () => call(offlineMode: true),
    'anonymous mode': () => call(anonymousMode: true),
    'auto-ping running': () => call(autoPingActive: true),
    'auto-reconnecting': () => call(autoReconnecting: true),
    'no public key': () => call(pubkey: null),
    'empty public key': () => call(pubkey: ''),
    'declined before': () => call(declined: true),
    'already linked': () => call(linked: true),
    'firmware cannot sign': () => call(signUnsupported: true),
    'already prompted this app session': () =>
        call(promptedThisAppSession: true),
  };

  skipRows.forEach((name, invoke) {
    test('skips when $name', () {
      expect(invoke(), LinkFlowDecision.skip);
    });
  });

  test('several blockers at once still skip', () {
    expect(
      call(loggedIn: false, offlineMode: true, linked: true),
      LinkFlowDecision.skip,
    );
  });

  test('a lowercase pubkey is still acceptable input', () {
    expect(call(pubkey: goodPubkey.toLowerCase()), LinkFlowDecision.prompt);
  });
}
