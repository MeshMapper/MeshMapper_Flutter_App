import 'package:flutter/services.dart';

import 'fix_altitude.dart';

/// Asks the Android side to describe the location provider's most recent
/// fix object, so the altitude rule can prove which value the location
/// plugin delivered (see `fix_altitude.dart`). Android only. Every failure
/// answers null and says nothing: the resolver stores unknown and owns the
/// one throttled `[GPS]` warning, so a flapping channel cannot log per fix.
class AndroidAltitudeChannel {
  AndroidAltitudeChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('meshmapper/altitude');

  final MethodChannel _channel;

  Future<NativeAltitudeAnswer?> describeLastFix() async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('describeLastFix');
      return NativeAltitudeAnswer.tryFromMap(raw);
    } catch (_) {
      // MissingPluginException, PlatformException or a codec error alike.
      return null;
    }
  }
}
