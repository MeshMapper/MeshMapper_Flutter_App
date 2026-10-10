import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/android_altitude_channel.dart';

/// The Dart side of the Android altitude channel: one method, no arguments,
/// and every failure answers null so the resolver stores unknown.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('meshmapper/altitude');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('parses a fused answer', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'describeLastFix');
      expect(call.arguments, isNull);
      return {
        'sdk': 34,
        'fixes': [
          {
            'source': 'fused',
            'timeMs': 1760000000000,
            'lat': 45.0,
            'lon': -75.0,
            'hasAltitude': true,
            'altitude': 120.0,
            'hasVerticalAccuracy': true,
            'verticalAccuracy': 8.0,
            'hasMsl': true,
            'msl': 84.0,
            'hasMslAccuracy': true,
            'mslAccuracy': 4.0,
            'isMock': false,
          }
        ],
      };
    });
    final answer = await AndroidAltitudeChannel(channel: channel).describeLastFix();
    expect(answer!.sdk, 34);
    expect(answer.fixes.single.msl, 84.0);
  });

  test('a platform exception answers null', () async {
    messenger.setMockMethodCallHandler(
        channel, (call) async => throw PlatformException(code: 'boom'));
    expect(await AndroidAltitudeChannel(channel: channel).describeLastFix(),
        isNull);
  });

  test('a missing plugin answers null', () async {
    // No handler registered: the binding throws MissingPluginException.
    expect(await AndroidAltitudeChannel(channel: channel).describeLastFix(),
        isNull);
  });

  test('a non-map answer is null', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => 'nope');
    expect(await AndroidAltitudeChannel(channel: channel).describeLastFix(),
        isNull);
  });
}
