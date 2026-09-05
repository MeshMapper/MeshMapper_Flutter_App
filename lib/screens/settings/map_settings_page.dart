import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../providers/app_state_provider.dart';
import '../offline_maps_screen.dart';
import 'settings_section_card.dart';

/// Settings folder: Map.
class MapSettingsPage extends StatelessWidget {
  const MapSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    final prefs = appState.preferences;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 40,
        title: const Text('Map', style: TextStyle(fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          SettingsSectionCard(children: [
            if (!kIsWeb)
              ListTile(
                leading: const Icon(Icons.download_for_offline),
                title: const Text('Offline Maps'),
                subtitle: const Text('Download map areas for offline use'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const OfflineMapsScreen(),
                    ),
                  );
                },
              ),
            SwitchListTile(
              secondary:
                  Icon(prefs.mapTilesEnabled ? Icons.cloud : Icons.cloud_off),
              title: const Text('Use Downloaded Tiles Only'),
              subtitle: Text(prefs.mapTilesEnabled
                  ? 'Online tiles load normally'
                  : 'Only downloaded areas are shown · no network tile requests'),
              value: !prefs.mapTilesEnabled,
              onChanged: (value) {
                appState
                    .updatePreferences(prefs.copyWith(mapTilesEnabled: !value));
              },
            ),
            if (prefs.mapTilesEnabled)
              ListTile(
                leading: const Icon(Icons.opacity),
                title: const Text('Coverage Overlay Opacity'),
                subtitle: Slider(
                  value: prefs.coverageOverlayOpacity.clamp(0.3, 1.0),
                  min: 0.3,
                  max: 1.0,
                  divisions: 7,
                  label: '${(prefs.coverageOverlayOpacity * 100).round()}%',
                  onChanged: (value) =>
                      appState.setCoverageOverlayOpacity(value),
                ),
                trailing:
                    Text('${(prefs.coverageOverlayOpacity * 100).round()}%'),
              ),
            if (prefs.mapTilesEnabled)
              ListTile(
                leading: const Icon(Icons.grid_on),
                title: const Text('Grid Mode'),
                subtitle: Text(prefs.coverageGridSize == 100
                    ? 'Detailed (More detailed cells, non grouped repeaters)'
                    : 'Simplified (Merged cells, grouped repeaters)'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showCoverageGridSelector(context, appState),
              ),
            ListTile(
              leading: const Icon(Icons.visibility),
              title: const Text('Color Vision'),
              subtitle: Text(_colorVisionLabel(prefs.colorVisionType)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _showColorVisionSelector(context, appState),
            ),
            ListTile(
              leading: const Icon(Icons.place),
              title: const Text('Map Marker Style'),
              subtitle: Text(_markerStyleLabel(prefs.markerStyle)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _showMarkerStyleSelector(context, appState),
            ),
            ListTile(
              leading: const Icon(Icons.my_location),
              title: const Text('GPS Marker'),
              subtitle: Text(_gpsMarkerLabel(prefs.gpsMarkerStyle)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _showGpsMarkerSelector(context, appState),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.cell_tower),
              title: const Text('Top Repeaters on Map'),
              subtitle:
                  const Text('Show top 3 repeaters by SNR from last ping'),
              value: prefs.showTopRepeaters,
              onChanged: (value) {
                appState
                    .updatePreferences(prefs.copyWith(showTopRepeaters: value));
              },
            ),
            // Live Activities are iOS-only, so the switch would be inert
            // anywhere else.
            if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS)
              SwitchListTile(
                secondary: const Icon(Icons.badge),
                title: const Text('Repeater Names on Live Activity'),
                subtitle: Text(prefs.liveActivityShowNames
                    ? 'Named rows on CarPlay and watch'
                    : 'Compact grid fits more repeaters'),
                value: prefs.liveActivityShowNames,
                onChanged: (value) {
                  appState.updatePreferences(
                      prefs.copyWith(liveActivityShowNames: value));
                },
              ),
          ]),
        ],
      ),
    );
  }

  String _markerStyleLabel(String style) {
    switch (style) {
      case 'circle':
        return 'Outlined Dot';
      case 'pin':
        return 'Pin';
      case 'diamond':
        return 'Diamond';
      case 'dot':
      default:
        return 'Dot';
    }
  }

  String _gpsMarkerLabel(String style) {
    switch (style) {
      case 'car':
        return 'Car';
      case 'bike':
        return 'Bike';
      case 'boat':
        return 'Boat';
      case 'walk':
        return 'Walk';
      case 'dog':
        return 'Dog';
      case 'chomper':
        return 'Chomper';
      case 'arrow':
      default:
        return 'Arrow';
    }
  }

  void _showMarkerStyleSelector(
      BuildContext context, AppStateProvider appState) {
    final options = [
      ('dot', 'Dot', Icons.circle),
      ('circle', 'Outlined Dot', Icons.circle_outlined),
      ('pin', 'Pin', Icons.place),
      ('diamond', 'Diamond', Icons.diamond),
    ];
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('Map Marker Style',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            RadioGroup<String>(
              groupValue: appState.preferences.markerStyle,
              onChanged: (v) {
                if (v != null) {
                  appState.updatePreferences(
                      appState.preferences.copyWith(markerStyle: v));
                }
                Navigator.pop(context);
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (value, label, icon) in options)
                    RadioListTile<String>(
                      secondary: Icon(icon),
                      title: Text(label),
                      value: value,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showGpsMarkerSelector(BuildContext context, AppStateProvider appState) {
    final options = <(String, String, Widget)>[
      ('arrow', 'Arrow', const Icon(Icons.navigation)),
      ('car', 'Car', const Icon(Icons.directions_car)),
      ('bike', 'Bike', const Icon(Icons.directions_bike)),
      ('boat', 'Boat', const Icon(Icons.directions_boat)),
      ('walk', 'Walk', const Icon(Icons.directions_walk)),
      ('dog', 'Dog', const FaIcon(FontAwesomeIcons.dog)),
      ('chomper', 'Chomper', const _ChomperIcon()),
    ];
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('GPS Marker',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            RadioGroup<String>(
              groupValue: appState.preferences.gpsMarkerStyle,
              onChanged: (v) {
                if (v != null) {
                  appState.updatePreferences(
                      appState.preferences.copyWith(gpsMarkerStyle: v));
                }
                Navigator.pop(context);
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (value, label, icon) in options)
                    RadioListTile<String>(
                      secondary: icon,
                      title: Text(label),
                      value: value,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  String _colorVisionLabel(String type) {
    return switch (type) {
      'protanopia' => 'Protanopia (red-blind)',
      'deuteranopia' => 'Deuteranopia (green-blind)',
      'tritanopia' => 'Tritanopia (blue-blind)',
      'achromatopsia' => 'Achromatopsia (monochrome)',
      _ => 'Default',
    };
  }

  /// Grid Mode preset selector — mirrors the web UI's Grid Mode
  /// (Simplified = 300 m, Detailed = 100 m + blob, applied server-side).
  void _showCoverageGridSelector(
      BuildContext context, AppStateProvider appState) {
    final options = [
      (300, 'Simplified', 'Merged cells, grouped repeaters'),
      (100, 'Detailed', 'More detailed cells, non grouped repeaters'),
    ];
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('Grid Mode',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            RadioGroup<int>(
              groupValue: appState.preferences.coverageGridSize,
              onChanged: (v) {
                if (v != null) {
                  appState.updatePreferences(
                      appState.preferences.copyWith(coverageGridSize: v));
                }
                Navigator.pop(context);
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (value, label, subtitle) in options)
                    RadioListTile<int>(
                      secondary: const Icon(Icons.grid_on),
                      title: Text(label),
                      subtitle:
                          Text(subtitle, style: const TextStyle(fontSize: 12)),
                      value: value,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showColorVisionSelector(
      BuildContext context, AppStateProvider appState) {
    final options = [
      ('none', 'Default', 'Standard color palette'),
      (
        'protanopia',
        'Protanopia',
        'Red-blind — difficulty distinguishing red and green'
      ),
      (
        'deuteranopia',
        'Deuteranopia',
        'Green-blind — difficulty distinguishing red and green'
      ),
      (
        'tritanopia',
        'Tritanopia',
        'Blue-blind — difficulty distinguishing blue and yellow'
      ),
      (
        'achromatopsia',
        'Achromatopsia',
        'Total color blindness — sees in greyscale'
      ),
    ];
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('Color Vision',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            RadioGroup<String>(
              groupValue: appState.preferences.colorVisionType,
              onChanged: (v) {
                if (v != null) appState.setColorVisionType(v);
                Navigator.pop(context);
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (value, label, subtitle) in options)
                    RadioListTile<String>(
                      secondary: const Icon(Icons.visibility),
                      title: Text(label),
                      subtitle:
                          Text(subtitle, style: const TextStyle(fontSize: 12)),
                      value: value,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// Chomper icon widget for the GPS marker selector
class _ChomperIcon extends StatelessWidget {
  const _ChomperIcon();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(24, 24),
      painter: _ChomperIconPainter(
        color: IconTheme.of(context).color ?? Colors.grey,
      ),
    );
  }
}

class _ChomperIconPainter extends CustomPainter {
  final Color color;
  const _ChomperIconPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    const radius = 10.0;

    const mouthAngle = 70.0 * (math.pi / 180);
    // Mouth faces right for the settings icon (natural reading direction)
    const startAngle = mouthAngle / 2;
    const sweepAngle = 2 * math.pi - mouthAngle;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final path = Path()
      ..moveTo(cx, cy)
      ..arcTo(
        Rect.fromCircle(center: Offset(cx, cy), radius: radius),
        startAngle,
        sweepAngle,
        false,
      )
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _ChomperIconPainter oldDelegate) =>
      color != oldDelegate.color;
}
