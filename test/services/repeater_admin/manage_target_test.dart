import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/repeater.dart';
import 'package:mesh_mapper/services/meshcore/connection.dart';
import 'package:mesh_mapper/services/repeater_admin/manage_target.dart';

Repeater rep(String hex, {String id = '00'}) => Repeater(
    id: id, hexId: hex, name: 'R$id', lat: 1, lon: 1, lastHeard: 0, enabled: 1);

void main() {
  final a = rep('4E7A${'00' * 30}', id: '4E');
  final b = rep('4E7B${'11' * 30}', id: '4F');
  final short = rep('4E7A3B', id: '4C'); // no full key: never a target

  group('resolveManageTarget', () {
    test('a picked repeater wins while the text still prefixes it', () {
      expect(resolveManageTarget(typedId: '4E7A', picked: a, repeaters: [a, b]), a);
      expect(resolveManageTarget(typedId: '', picked: a, repeaters: [a, b]), a);
    });
    test('a picked repeater is dropped when the text no longer matches', () {
      expect(resolveManageTarget(typedId: '4E7B', picked: a, repeaters: [a, b]), b);
    });
    test('a unique typed prefix resolves', () {
      expect(resolveManageTarget(typedId: '4e7b', picked: null, repeaters: [a, b]), b);
    });
    test('an ambiguous prefix is null', () {
      expect(resolveManageTarget(typedId: '4E', picked: null, repeaters: [a, b]), isNull);
    });
    test('empty text with nothing picked is null', () {
      expect(resolveManageTarget(typedId: '', picked: null, repeaters: [a, b]), isNull);
    });
    test('a repeater without a full key is never a target', () {
      expect(resolveManageTarget(typedId: '4E7A3B', picked: null, repeaters: [short]), isNull);
      expect(resolveManageTarget(typedId: '4E7A3B', picked: short, repeaters: [short]), isNull);
    });
  });

  group('manageBlockReason', () {
    String? reason({bool connected = true, bool mode = false, bool inProgress = false,
        bool sending = false, bool admin = false, bool reconnecting = false,
        bool firmwareOk = true}) =>
        manageBlockReason(
            isConnected: connected,
            isAnyModeRunning: mode,
            isPingInProgress: inProgress,
            isPingSending: sending,
            isRepeaterAdminActive: admin,
            isAutoReconnecting: reconnecting,
            companionFirmwareSupported: firmwareOk);

    test('allowed', () => expect(reason(), isNull));
    test('not connected', () => expect(reason(connected: false), 'Connect a radio to manage this repeater'));
    test('mode running', () => expect(reason(mode: true), 'Stop the running mode first'));
    test('ping in flight', () {
      expect(reason(inProgress: true), 'Wait for the current ping to finish');
      expect(reason(sending: true), 'Wait for the current ping to finish');
    });
    test('session already open', () => expect(reason(admin: true), 'A repeater session is already open'));
    test('reconnecting counts as not connected', () =>
        expect(reason(reconnecting: true), 'Connect a radio to manage this repeater'));
    test('connection outranks the mode', () =>
        expect(reason(connected: false, mode: true), 'Connect a radio to manage this repeater'));
    test('old companion firmware, once connected', () {
      expect(reason(firmwareOk: false), 'Update companion firmware to use Manage');
      expect(reason(connected: false, firmwareOk: false), 'Connect a radio to manage this repeater');
    });
  });

  group('companion repeater administration support', () {
    bool supported(int code, String? version) {
      final device = DeviceQueryResponse(
        protocolVersion: code,
        manufacturer: 'Test companion',
        firmwareVersionString: version,
      );
      return companionSupportsRepeaterAdmin(device.protocolVersion);
    }

    test('unknown companion capabilities are refused', () {
      expect(companionSupportsRepeaterAdmin(null), isFalse);
    });
    test('accepts the minimum companion capability code', () {
      expect(supported(7, 'v1.9.0'), isTrue);
    });
    test('accepts a fork with independent release numbering', () {
      expect(supported(14, 'v1.4.4'), isTrue);
    });
    test('accepts supported firmware without a release string', () {
      expect(supported(7, null), isTrue);
      expect(supported(7, ''), isTrue);
      expect(supported(14, 'nightly'), isTrue);
    });
    test('rejects an old capability code despite a newer release string', () {
      expect(supported(6, 'v1.14.0'), isFalse);
      expect(supported(0, 'v2.0.0'), isFalse);
    });
  });
}
