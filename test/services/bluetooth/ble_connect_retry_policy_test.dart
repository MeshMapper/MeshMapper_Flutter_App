import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/bluetooth/ble_connect_retry_policy.dart';

/// #500: connect() only treated Android error 133 as retryable, so the 15s
/// GATT connect timeout, transient GATT errors and service discovery failures
/// all rethrew on attempt 1 of 3, and a handshake that died right after the
/// transport connected aborted the whole connection. Users had to tap Connect
/// 4-7 times to do the work the retry loop was supposed to do.
void main() {
  group('classifyBleConnectFailure', () {
    BleConnectFailureAction classify(String error,
        {bool isIos = false, int attempt = 1, int maxRetries = 3}) {
      return classifyBleConnectFailure(
        errorString: error,
        isIos: isIos,
        attempt: attempt,
        maxRetries: maxRetries,
      );
    }

    test('retries the 15s GATT connect timeout', () {
      expect(
        classify(
            'FlutterBluePlusException | connect | fbp-code: 1 | Timed out after 15s'),
        BleConnectFailureAction.retry,
      );
    });

    test('still retries Android error 133', () {
      expect(
        classify(
            'FlutterBluePlusException | connect | android-code: 133 | GATT_ERROR'),
        BleConnectFailureAction.retry,
      );
    });

    test('retries transient GATT errors from setNotifyValue', () {
      expect(
        classify(
            'FlutterBluePlusException | setNotifyValue | android-code: 28 | UNKNOWN_GATT_ERROR',
            attempt: 2),
        BleConnectFailureAction.retry,
      );
    });

    test('retries a device drop during setup', () {
      expect(
        classify(
            'FlutterBluePlusException | discoverServices | fbp-code: 6 | Device is disconnected'),
        BleConnectFailureAction.retry,
      );
    });

    test('retries service discovery failures', () {
      expect(
        classify('Exception: MeshCore service not found'),
        BleConnectFailureAction.retry,
      );
    });

    test('fails once attempts are exhausted', () {
      expect(
        classify(
            'FlutterBluePlusException | connect | fbp-code: 1 | Timed out after 15s',
            attempt: 3),
        BleConnectFailureAction.fail,
      );
    });

    test('aborts on iOS bond error apple-code 14 without burning retries', () {
      expect(
        classify(
            'FlutterBluePlusException | connect | apple-code: 14 | Peer removed pairing information',
            isIos: true),
        BleConnectFailureAction.abortForBondError,
      );
    });

    test('aborts on iOS bond error apple-code 15', () {
      expect(
        classify(
            'FlutterBluePlusException | connect | apple-code: 15 | Failed to encrypt the connection',
            isIos: true),
        BleConnectFailureAction.abortForBondError,
      );
    });

    test('bond error strings on Android are plain retryable errors', () {
      expect(
        classify('Exception: apple-code: 14', isIos: false),
        BleConnectFailureAction.retry,
      );
    });
  });

  group('shouldRerunConnectionWorkflow', () {
    bool rerun({
      bool transportConnected = true,
      Duration? sinceTransportConnect = const Duration(seconds: 3),
      String error = 'TimeoutException: Device query timed out',
      bool isAutoReconnecting = false,
      bool userRequestedDisconnect = false,
      bool alreadyRerun = false,
    }) {
      return shouldRerunConnectionWorkflow(
        transportConnected: transportConnected,
        sinceTransportConnect: sinceTransportConnect,
        errorString: error,
        isAutoReconnecting: isAutoReconnecting,
        userRequestedDisconnect: userRequestedDisconnect,
        alreadyRerun: alreadyRerun,
      );
    }

    test('reruns when the handshake dies right after transport connect', () {
      expect(rerun(), isTrue);
    });

    test('covers a 15s writeCharacteristic timeout inside the window', () {
      expect(
        rerun(
          sinceTransportConnect: const Duration(seconds: 16),
          error:
              'FlutterBluePlusException | writeCharacteristic | fbp-code: 1 | Timed out after 15s',
        ),
        isTrue,
      );
    });

    test('does not rerun long after the transport connected', () {
      expect(
        rerun(sinceTransportConnect: const Duration(seconds: 30)),
        isFalse,
      );
    });

    test('does not rerun when the transport never connected', () {
      expect(
        rerun(transportConnected: false, sinceTransportConnect: null),
        isFalse,
      );
    });

    test('never reruns a server auth rejection', () {
      expect(
        rerun(error: 'Exception: AUTH_FAILED:zone_full:Zone is full'),
        isFalse,
      );
    });

    test('never reruns a disposed connection', () {
      expect(
        rerun(error: 'Exception: Connection instance has been disposed'),
        isFalse,
      );
    });

    test('reruns only once', () {
      expect(rerun(alreadyRerun: true), isFalse);
    });

    test('defers to the auto-reconnect machinery', () {
      expect(rerun(isAutoReconnecting: true), isFalse);
    });

    test('does not rerun after a user-requested disconnect', () {
      expect(rerun(userRequestedDisconnect: true), isFalse);
    });

    test('never reruns an attempt superseded by a newer connect', () {
      expect(
        rerun(error: 'Exception: Connection attempt superseded'),
        isFalse,
      );
    });
  });
}
