import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/server_config.dart';
import 'package:mesh_mapper/services/server_switch_rules.dart';

String? _reason({
  bool radioConnected = false,
  bool connecting = false,
  bool sessionActive = false,
  int queuedUploads = 0,
  bool uploading = false,
  int unsavedOfflinePings = 0,
}) =>
    serverSwitchBlockReason(
      radioConnected: radioConnected,
      connecting: connecting,
      sessionActive: sessionActive,
      queuedUploads: queuedUploads,
      uploading: uploading,
      unsavedOfflinePings: unsavedOfflinePings,
    );

void main() {
  test('allowed when nothing of the current server is in flight', () {
    expect(_reason(), isNull);
  });

  test('refused while a wardrive session is active, saying so', () {
    final reason = _reason(sessionActive: true, radioConnected: true);
    expect(reason, contains('session is active'));
    expect(reason, contains('Disconnect'));
  });

  test('refused while a radio is connected or connecting', () {
    expect(_reason(radioConnected: true), contains('radio is connected'));
    expect(_reason(connecting: true), contains('radio is connected'));
  });

  test('refused while pings are waiting to upload, with the count', () {
    expect(_reason(queuedUploads: 1), contains('1 ping is still waiting'));
    expect(_reason(queuedUploads: 12), contains('12 pings are still waiting'));
  });

  test('refused while an upload is running', () {
    expect(_reason(uploading: true), contains('upload is in progress'));
  });

  test('refused while an offline drive is not saved yet', () {
    expect(_reason(unsavedOfflinePings: 3), contains('offline drive'));
  });

  test('every refusal is a full sentence', () {
    for (final reason in [
      _reason(sessionActive: true),
      _reason(radioConnected: true),
      _reason(queuedUploads: 2),
      _reason(uploading: true),
      _reason(unsavedOfflinePings: 1),
    ]) {
      expect(reason, isNotNull);
      expect(reason, endsWith('.'));
    }
  });

  group('a refused key', () {
    tearDown(ServerConfig.resetForTest);

    test('on Live keeps the wording it always had', () {
      ServerConfig.resetForTest();
      expect(badKeyMessage(), 'Invalid API key. Please check configuration.');
    });

    test('on the dev server names that server', () {
      ServerConfig.useDev(key: 'some-key');
      expect(badKeyMessage(), 'This key is not valid on dev.meshmapper.net.');
    });
  });
}
