import 'package:flutter/painting.dart';

/// The fill colours one GPS position marker is painted with.
///
/// Every marker style has a white outline and a [body] fill; the car's
/// windshield and the dog's ear use [shade], the boat's sail uses [light].
class GpsMarkerColors {
  /// Main fill.
  final Color body;

  /// Darker detail drawn on top of [body].
  final Color shade;

  /// Lighter detail drawn beside [body].
  final Color light;

  const GpsMarkerColors({
    required this.body,
    required this.shade,
    required this.light,
  });

  /// Stored value of the default colour.
  static const String defaultChoice = 'default';

  /// Stored value of the green colour.
  static const String greenChoice = 'green';

  /// Every colour choice, in picker order.
  static const List<String> choices = [defaultChoice, greenChoice];

  /// Material blue, the colour every style but Chomper has always used.
  static const blue = GpsMarkerColors(
    body: Color(0xFF2196F3),
    shade: Color(0xFF1565C0),
    light: Color(0xFF64B5F6),
  );

  /// Chomper's own default: cyan.
  static const cyan = GpsMarkerColors(
    body: Color(0xFF00BCD4),
    shade: Color(0xFF00838F),
    light: Color(0xFF4DD0E1),
  );

  /// A dark Material green. Darker than the pale green of a bidirectional
  /// coverage square (`#7EE094`), so the marker stands apart from the
  /// coverage under it by lightness as well as by its white outline. Like the
  /// blue, it does not change with Color Vision: it is the user's own pick,
  /// not a semantic colour, and the white outline separates it from the
  /// coverage under any palette.
  static const green = GpsMarkerColors(
    body: Color(0xFF388E3C),
    shade: Color(0xFF1B5E20),
    light: Color(0xFF81C784),
  );

  /// A stored choice, with anything unknown (a missing value, or one a newer
  /// version wrote) read as [defaultChoice].
  static String normalize(String? choice) =>
      choices.contains(choice) ? choice! : defaultChoice;

  /// The colours [style] is painted with for [choice]. The default keeps each
  /// style's own colour: blue, or cyan for Chomper.
  static GpsMarkerColors forStyle(String style, String choice) {
    if (normalize(choice) == greenChoice) return green;
    return style == 'chomper' ? cyan : blue;
  }
}
