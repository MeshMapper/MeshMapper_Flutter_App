import 'dart:ui' show Color;

/// An sRGB colour resolved from the active colour-vision palette.
///
/// Resolving on the phone is deliberate: Dart owns the palettes, while native
/// glance surfaces receive the same small RGB value and never need to duplicate
/// accessibility policy.
class WatchColor {
  const WatchColor(this.r, this.g, this.b);

  factory WatchColor.fromColor(Color color) => WatchColor(
        (color.r * 255.0).roundToDouble() / 255.0,
        (color.g * 255.0).roundToDouble() / 255.0,
        (color.b * 255.0).roundToDouble() / 255.0,
      );

  final double r;
  final double g;
  final double b;

  Map<String, Object?> toMap() => {'r': r, 'g': g, 'b': b};

  @override
  bool operator ==(Object other) =>
      other is WatchColor && other.r == r && other.g == g && other.b == b;

  @override
  int get hashCode => Object.hash(r, g, b);
}
