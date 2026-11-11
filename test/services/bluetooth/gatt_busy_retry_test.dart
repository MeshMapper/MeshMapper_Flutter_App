import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/bluetooth/mobile_bluetooth.dart';

void main() {
  const busy = 'gatt.writeCharacteristic() returned 201 : '
      'ERROR_GATT_WRITE_REQUEST_BUSY';
  Future<void> noSleep(Duration _) async {}

  test('retries a busy write until it goes out', () async {
    var calls = 0;
    await writeRetryingGattBusy(() async {
      calls++;
      if (calls < 3) throw Exception(busy);
    }, sleep: noSleep);
    expect(calls, 3);
  });

  test('gives up after the last retry with the original error', () async {
    var calls = 0;
    await expectLater(
      writeRetryingGattBusy(() async {
        calls++;
        throw Exception(busy);
      }, sleep: noSleep),
      throwsA(predicate((Object? e) => e != null && isGattWriteBusy(e))),
    );
    expect(calls, kGattBusyRetryDelays.length + 1);
  });

  test('never retries another error', () async {
    var calls = 0;
    await expectLater(
      writeRetryingGattBusy(() async {
        calls++;
        throw Exception('device is disconnected');
      }, sleep: noSleep),
      throwsException,
    );
    expect(calls, 1);
  });
}
