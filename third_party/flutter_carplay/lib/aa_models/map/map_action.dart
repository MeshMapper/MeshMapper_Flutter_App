import 'package:uuid/uuid.dart';

/// DELTA D from upstream 1.6.5: an action in a map action strip.
///
/// The strip is the vertical bar the host draws down the right edge of the map
/// region. Its constraints are stricter than a pane's — `ACTIONS_CONSTRAINTS_MAP`
/// allows at most 4 actions and 1 primary, and leaves `maxCustomTitles` at 0, so
/// **an action without an icon is rejected**. [imageUrl] is therefore required,
/// not decorative; [title] is carried only for accessibility and for the
/// host to use if it ever renders one.
class AAMapAction {
  AAMapAction({
    required this.title,
    required this.imageUrl,
    this.isPrimary = false,
    this.onPress,
    String? id,
  })  : assert(title.isNotEmpty, 'AAMapAction.title cannot be empty'),
        assert(imageUrl.isNotEmpty,
            'AAMapAction.imageUrl is required — the map strip is icon-only'),
        _elementId = id ?? const Uuid().v4();

  final String _elementId;
  final String title;

  /// Flutter asset path, file:// path or network URL — resolved to a CarIcon
  /// natively by the same loader pane and grid images use.
  final String imageUrl;

  final bool isPrimary;
  final Function()? onPress;

  String get uniqueId => _elementId;

  Map<String, dynamic> toJson() => {
        '_elementId': _elementId,
        'title': title,
        'imageUrl': imageUrl,
        'isPrimary': isPrimary,
        'onPress': onPress != null,
      };
}
