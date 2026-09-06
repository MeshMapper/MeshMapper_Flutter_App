import 'package:uuid/uuid.dart';

import '../template.dart';
import 'map_action.dart';

/// DELTA D from upstream 1.6.5: Android Auto's MapWithContentTemplate.
///
/// The host renders no map here. It reserves a map region and hands the app a
/// Surface through `AppManager.setSurfaceCallback`; whatever the app draws onto
/// that Surface is the map. See `FAASurfaceProvider` on the native side.
///
/// [contentTemplate] is any supported template — it is dispatched through the
/// same builder as a root template — and occupies the content half beside the
/// map.
///
/// Requires car API level 7, the `androidx.car.app.MAP_TEMPLATES` and
/// `androidx.car.app.ACCESS_SURFACE` permissions, and an app category permitted
/// to draw maps (navigation, POI, or weather — **not** IOT).
class AAMapWithContentTemplate implements AATemplate {
  AAMapWithContentTemplate({
    required this.contentTemplate,
    this.mapActions = const [],
    String? id,
  })  : assert(mapActions.length <= 4,
            'A map action strip cannot hold more than 4 actions'),
        assert(
          mapActions.where((AAMapAction a) => a.isPrimary).length <= 1,
          'A map action strip cannot hold more than 1 primary action',
        ),
        _elementId = id ?? const Uuid().v4();

  final String _elementId;
  final AATemplate contentTemplate;

  /// The vertical strip down the right edge of the map. Empty means no strip.
  final List<AAMapAction> mapActions;

  @override
  String get uniqueId => _elementId;

  /// The native side needs the content's runtime type to dispatch it, exactly
  /// as the root template does.
  static String runtimeTypeOf(AATemplate template) {
    final name = template.runtimeType.toString();
    return name.startsWith('AA') ? 'FAA${name.substring(2)}' : 'FAA$name';
  }

  @override
  Map<String, dynamic> toJson() => {
        '_elementId': _elementId,
        'contentRuntimeType': runtimeTypeOf(contentTemplate),
        'contentTemplate': contentTemplate.toJson(),
        'mapActions':
            mapActions.map((AAMapAction action) => action.toJson()).toList(),
      };
}
