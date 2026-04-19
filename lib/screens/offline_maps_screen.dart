import 'dart:math' show Point;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:provider/provider.dart';

import '../providers/app_state_provider.dart';
import '../services/offline_map_service.dart';
import '../utils/debug_logger_io.dart';
import '../widgets/app_toast.dart';
import '../widgets/map_widget.dart' show MapStyle, MapStyleExtension;

/// Label → URL map for styles the user can download, derived from
/// [MapStyle.downloadable]. Satellite is excluded (inline raster JSON
/// doesn't work with MapLibre's offline region downloader).
final Map<String, String> _downloadStyles = {
  for (final s in MapStyleExtension.downloadable) s.label: s.styleUrl,
};

/// Screen for managing offline map tile downloads.
///
/// Accessible from the Settings screen. The underlying [OfflineMapService]
/// lives at the app level (via Provider), so downloads continue even after
/// navigating away from this screen. A system notification shows progress.
class OfflineMapsScreen extends StatefulWidget {
  const OfflineMapsScreen({super.key});

  @override
  State<OfflineMapsScreen> createState() => _OfflineMapsScreenState();
}

class _OfflineMapsScreenState extends State<OfflineMapsScreen> {
  @override
  void initState() {
    super.initState();
    // Listen for background download completions to show a toast.
    final service = context.read<OfflineMapService>();
    service.addListener(_onServiceUpdate);
  }

  @override
  void dispose() {
    // Use try-catch in case the provider is already disposed during app teardown.
    try {
      context.read<OfflineMapService>().removeListener(_onServiceUpdate);
    } catch (_) {}
    super.dispose();
  }

  void _onServiceUpdate() {
    if (!mounted) return;
    final service = context.read<OfflineMapService>();
    final completed = service.consumeLastCompletedName();
    if (completed != null) {
      AppToast.success(context, '"$completed" downloaded');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final service = context.watch<OfflineMapService>();

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 40,
        title: const Text('Offline Maps', style: TextStyle(fontSize: 18)),
      ),
      body: !service.initialized
          ? const Center(child: CircularProgressIndicator())
          : kIsWeb
              ? _buildWebUnsupported(theme)
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                  children: [
                    _buildStorageCard(context, service, theme, isDark),
                    const SizedBox(height: 8),
                    _buildDownloadedRegionsCard(
                        context, service, theme, isDark),
                    const SizedBox(height: 8),
                    if (service.isDownloading)
                      _buildDownloadProgressCard(
                          context, service, theme, isDark),
                  ],
                ),
      floatingActionButton:
          (service.initialized && !kIsWeb && !service.isDownloading)
              ? FloatingActionButton.extended(
                  heroTag: null,
                  onPressed: () => _showDownloadDialog(context),
                  icon: const Icon(Icons.download),
                  label: const Text('Download Region'),
                )
              : null,
    );
  }

  Widget _buildWebUnsupported(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 64, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            Text(
              'Offline maps are not available on web',
              style: theme.textTheme.titleMedium
                  ?.copyWith(color: Colors.grey.shade500),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Use the mobile app to download map regions for offline use',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: Colors.grey.shade400),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  // ──────────────────────────────────────────────
  // Storage usage card
  // ──────────────────────────────────────────────

  Widget _buildStorageCard(BuildContext context, OfflineMapService service,
      ThemeData theme, bool isDark) {
    final usageRatio = service.usageRatio;
    final barColor = usageRatio > 0.9
        ? Colors.red
        : usageRatio > 0.7
            ? Colors.orange
            : theme.colorScheme.primary;

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Storage',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => _showStorageLimitDialog(context, service),
                  icon: const Icon(Icons.tune, size: 16),
                  label: const Text('Limit'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Usage bar
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: usageRatio,
                minHeight: 20,
                backgroundColor: isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.grey.shade200,
                color: barColor,
              ),
            ),
            const SizedBox(height: 8),

            // Usage text
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '~${service.totalUsedDisplay} used (estimated)',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: barColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${service.storageLimitDisplay} limit',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.grey,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              'Based on tile count heuristic; actual disk use may differ.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.grey,
                fontSize: 11,
                fontStyle: FontStyle.italic,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${service.regions.length} region${service.regions.length == 1 ? '' : 's'} downloaded',
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.grey.shade500,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ──────────────────────────────────────────────
  // Downloaded regions list
  // ──────────────────────────────────────────────

  Widget _buildDownloadedRegionsCard(BuildContext context,
      OfflineMapService service, ThemeData theme, bool isDark) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
            child: Row(
              children: [
                Text(
                  'Downloaded Regions',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                if (service.regions.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 20),
                    onPressed: () => service.refreshRegions(),
                    tooltip: 'Refresh',
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
          if (service.regions.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                children: [
                  Icon(Icons.map_outlined,
                      size: 48, color: Colors.grey.shade400),
                  const SizedBox(height: 8),
                  Text(
                    'No offline regions downloaded',
                    style: TextStyle(color: Colors.grey.shade500),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Tap "Download Region" to save map tiles for offline use',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            )
          else
            ...service.regions.map(
              (region) => _RegionTile(
                region: region,
                onDelete: () => _confirmDeleteRegion(context, service, region),
              ),
            ),
          if (service.regions.length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: OutlinedButton.icon(
                onPressed: () => _confirmDeleteAll(context, service),
                icon: const Icon(Icons.delete_sweep, size: 18),
                label: const Text('Delete All'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                  side: const BorderSide(color: Colors.red, width: 0.5),
                  minimumSize: const Size.fromHeight(36),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────
  // Download progress card
  // ──────────────────────────────────────────────

  Widget _buildDownloadProgressCard(BuildContext context,
      OfflineMapService service, ThemeData theme, bool isDark) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Downloading',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        service.downloadingRegionName ?? 'Region',
                        style: theme.textTheme.bodyMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: service.downloadProgress ?? 0,
                          minHeight: 8,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '${((service.downloadProgress ?? 0) * 100).round()}%',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Download continues in the background if you leave this screen',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
            ),
            if (service.queueLength > 0) ...[
              const SizedBox(height: 4),
              Text(
                '${service.queueLength} more queued after this',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade500,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => _confirmCancelDownload(context, service),
                icon: const Icon(Icons.close, size: 16, color: Colors.red),
                label: const Text('Cancel',
                    style: TextStyle(color: Colors.red)),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmCancelDownload(
      BuildContext context, OfflineMapService service) async {
    final name = service.downloadingRegionName ?? 'this download';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel download?'),
        content: Text(
          'Tiles downloaded so far for "$name" will be discarded. '
          'Queued downloads (if any) will continue automatically.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep downloading'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Cancel download'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok = await service.cancelActiveDownload();
    if (context.mounted && ok) {
      AppToast.info(context, 'Download cancelled');
    }
  }

  // ──────────────────────────────────────────────
  // Storage limit dialog
  // ──────────────────────────────────────────────

  Future<void> _showStorageLimitDialog(
      BuildContext context, OfflineMapService service) async {
    int currentLimit = service.storageLimitMb;

    final result = await showDialog<int>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: const Text('Storage Limit'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$currentLimit MB',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                  ),
                  const SizedBox(height: 16),
                  Slider(
                    value: currentLimit.toDouble(),
                    min: OfflineMapService.minStorageLimitMb.toDouble(),
                    max: OfflineMapService.maxStorageLimitMb.toDouble(),
                    divisions: (OfflineMapService.maxStorageLimitMb -
                            OfflineMapService.minStorageLimitMb) ~/
                        50,
                    label: '$currentLimit MB',
                    onChanged: (value) {
                      setDialogState(() => currentLimit = value.round());
                    },
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${OfflineMapService.minStorageLimitMb} MB',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      Text(
                        '${OfflineMapService.maxStorageLimitMb} MB',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Currently using ~${service.totalUsedDisplay} (estimated)',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.grey,
                        ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, currentLimit),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result != null) {
      await service.setStorageLimit(result);
      if (context.mounted) {
        AppToast.success(context, 'Storage limit set to $result MB');
      }
    }
  }

  // ──────────────────────────────────────────────
  // Download new region dialog
  // ──────────────────────────────────────────────

  Future<void> _showDownloadDialog(BuildContext context) async {
    final started = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => const _DownloadRegionPage(),
      ),
    );

    // Toast is handled by the _onServiceUpdate listener when the download
    // completes (which may happen long after this page returns).
    if (started == true && context.mounted) {
      AppToast.simple(
          context, 'Download started — check notifications for progress');
    }
  }

  // ──────────────────────────────────────────────
  // Delete confirmations
  // ──────────────────────────────────────────────

  Future<void> _confirmDeleteRegion(BuildContext context,
      OfflineMapService service, OfflineMapRegion region) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Region?'),
        content: Text(
          'Delete "${region.name}"? This will free approximately '
          '${region.sizeDisplay} of storage.\n\n'
          'Note: shared tiles used by other regions may not be freed immediately.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final success = await service.deleteRegion(region.id);
      if (context.mounted) {
        if (success) {
          AppToast.success(context, '"${region.name}" deleted');
        } else {
          AppToast.error(
              context, service.consumeLastError() ?? 'Failed to delete region');
        }
      }
    }
  }

  Future<void> _confirmDeleteAll(
      BuildContext context, OfflineMapService service) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete All Regions?'),
        content: Text(
          'Delete all ${service.regions.length} downloaded regions? '
          'This will free approximately ${service.totalUsedDisplay}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await service.deleteAllRegions();
      if (context.mounted) {
        AppToast.success(context, 'All regions deleted');
      }
    }
  }
}

// ═══════════════════════════════════════════════
// Region list tile
// ═══════════════════════════════════════════════

class _RegionTile extends StatelessWidget {
  final OfflineMapRegion region;
  final VoidCallback onDelete;

  const _RegionTile({required this.region, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: _styleIcon(region.styleName),
      title: Text(
        region.name,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${region.styleName} · z${region.minZoom.round()}-${region.maxZoom.round()} · ${region.sizeDisplay}\n'
        '${region.boundsDisplay}',
        style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
      ),
      isThreeLine: true,
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
        onPressed: onDelete,
        tooltip: 'Delete',
      ),
    );
  }

  Widget _styleIcon(String styleName) {
    switch (styleName.toLowerCase()) {
      case 'dark':
        return const Icon(Icons.dark_mode);
      case 'light':
        return const Icon(Icons.light_mode);
      case 'satellite':
        return const Icon(Icons.satellite_alt);
      case 'liberty':
      default:
        return const Icon(Icons.map);
    }
  }
}

// ═══════════════════════════════════════════════
// Download region flow (full-page)
// ═══════════════════════════════════════════════

class _DownloadRegionPage extends StatefulWidget {
  const _DownloadRegionPage();

  @override
  State<_DownloadRegionPage> createState() => _DownloadRegionPageState();
}

class _DownloadRegionPageState extends State<_DownloadRegionPage> {
  final _nameController = TextEditingController();
  String _selectedStyle = 'Liberty';
  double _minZoom = 6;
  double _maxZoom = 14;
  bool _submitting = false;
  String? _error;

  // Default center (Ottawa)
  static const LatLng _defaultCenter = LatLng(45.4215, -75.6972);

  // Bounds selection via interactive map
  MapLibreMapController? _mapController;
  LatLng? _boundsNE;
  LatLng? _boundsSW;
  int _tapCount = 0;
  Line? _boundsLine;
  Fill? _boundsFill;

  // Existing region overlays
  final List<Fill> _existingFills = [];
  final List<Line> _existingLines = [];
  bool _showExisting = true;

  @override
  void initState() {
    super.initState();
    // grab user's current map style to start
    final pref = context.read<AppStateProvider>().preferences.mapStyle;
    final mapped = pref.substring(0, 1).toUpperCase() + pref.substring(1);
    if (_downloadStyles.containsKey(mapped)) {
      _selectedStyle = mapped;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  LatLngBounds? get _selectedBounds {
    if (_boundsNE == null || _boundsSW == null) return null;
    return LatLngBounds(southwest: _boundsSW!, northeast: _boundsNE!);
  }

  bool get _canSubmit =>
      _nameController.text.trim().isNotEmpty &&
      _selectedBounds != null &&
      !_submitting;

  int get _estimatedTiles {
    final bounds = _selectedBounds;
    if (bounds == null) return 0;
    return OfflineMapService.estimateTileCount(bounds, _minZoom, _maxZoom);
  }

  String get _estimatedSize {
    final bytes = OfflineMapService.estimateSizeBytes(_estimatedTiles);
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Determine map center - prefer current GPS, fallback to last known, then Ottawa
    LatLng center = _defaultCenter;
    if (appState.currentPosition != null) {
      center = LatLng(
        appState.currentPosition!.latitude,
        appState.currentPosition!.longitude,
      );
    } else if (appState.lastKnownPosition != null) {
      center = LatLng(
        appState.lastKnownPosition!.lat,
        appState.lastKnownPosition!.lon,
      );
    }

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 40,
        title: const Text('Download Region', style: TextStyle(fontSize: 18)),
      ),
      body: Column(
        children: [
          // Map for bounds selection
          Expanded(
            flex: 3,
            child: Stack(
              children: [
                MapLibreMap(
                  styleString: _downloadStyles[_selectedStyle]!,
                  initialCameraPosition: CameraPosition(
                    target: center, // Vancouver default
                    zoom: 10,
                  ),
                  onMapCreated: (controller) {
                    _mapController = controller;
                  },
                  onStyleLoadedCallback: () {
                    if (_showExisting) _drawExistingRegions();
                  },
                  onMapClick: _onMapTap,
                  rotateGesturesEnabled: false,
                  tiltGesturesEnabled: false,
                ),
                // Bounds instruction overlay
                Positioned(
                  top: 8,
                  left: 8,
                  right: 8,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: (isDark ? Colors.black : Colors.white)
                          .withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _selectedBounds != null
                          ? 'Region selected · ~$_estimatedTiles tiles · $_estimatedSize'
                          : _tapCount == 1
                              ? 'Tap the opposite corner to complete the region'
                              : 'Tap two corners on the map to select a region',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
                // Reset bounds button
                if (_selectedBounds != null)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Material(
                      type: MaterialType.circle,
                      color: theme.colorScheme.primaryContainer,
                      elevation: 2,
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: _resetBounds,
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Icon(Icons.restart_alt,
                              size: 20,
                              color: theme.colorScheme.onPrimaryContainer),
                        ),
                      ),
                    ),
                  ),
                // Existing regions toggle
                Positioned(
                  bottom: 8,
                  left: 8,
                  child: Material(
                    borderRadius: BorderRadius.circular(16),
                    color: (isDark ? Colors.black : Colors.white)
                        .withValues(alpha: 0.85),
                    elevation: 2,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: _toggleExistingRegions,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _showExisting
                                  ? Icons.visibility
                                  : Icons.visibility_off,
                              size: 14,
                              color: const Color(0xFFF59E0B),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${context.read<OfflineMapService>().regions.length} existing',
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontSize: 11,
                                color: _showExisting
                                    ? const Color(0xFFF59E0B)
                                    : Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Configuration panel
          Expanded(
            flex: 2,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Region name
                  TextField(
                    controller: _nameController,
                    decoration: InputDecoration(
                      labelText: 'Region Name',
                      hintText: 'e.g. Downtown Vancouver',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8)),
                      isDense: true,
                      prefixIcon: const Icon(Icons.label_outline, size: 20),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),

                  // Style selector
                  Row(
                    children: [
                      const Text('Style: ',
                          style: TextStyle(fontWeight: FontWeight.w500)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SegmentedButton<String>(
                          segments: _downloadStyles.keys
                              .map((s) => ButtonSegment<String>(
                                    value: s,
                                    label: Text(s,
                                        style: const TextStyle(fontSize: 12)),
                                  ))
                              .toList(),
                          selected: {_selectedStyle},
                          onSelectionChanged: (selected) {
                            setState(() => _selectedStyle = selected.first);
                          },
                          style: SegmentedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Zoom range
                  Row(
                    children: [
                      Text(
                        'Zoom: ${_minZoom.round()} – ${_maxZoom.round()}',
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                      const Spacer(),
                      Text(
                        '~$_estimatedTiles tiles',
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade500),
                      ),
                    ],
                  ),
                  RangeSlider(
                    values: RangeValues(_minZoom, _maxZoom),
                    // OpenFreeMap vector tiles max out at z14; z15+ is pure
                    // overzoom (duplicate tile data). Slider caps at 15 to
                    // leave one overzoom step reachable without letting users
                    // blow out storage at z16+.
                    min: 0,
                    max: 15,
                    divisions: 15,
                    labels: RangeLabels(
                      _minZoom.round().toString(),
                      _maxZoom.round().toString(),
                    ),
                    onChanged: (values) {
                      setState(() {
                        _minZoom = values.start;
                        _maxZoom = values.end;
                      });
                    },
                  ),

                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: Colors.red.withValues(alpha: 0.3)),
                      ),
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Colors.red, fontSize: 12),
                      ),
                    ),
                  ],

                  const SizedBox(height: 12),

                  // Download button
                  FilledButton.icon(
                    onPressed: _canSubmit ? _startDownload : null,
                    icon: _submitting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.download),
                    label:
                        Text(_submitting ? 'Starting...' : 'Download Region'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(44),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _onMapTap(Point<double> point, LatLng coordinates) {
    if (_tapCount == 0) {
      setState(() {
        _boundsSW = coordinates;
        _boundsNE = null;
        _tapCount = 1;
        _error = null;
        _clearBoundsOverlay();
      });
      return;
    }
    if (_tapCount != 1) return;

    // Ensure SW is actually southwest and NE is northeast
    final lat1 = _boundsSW!.latitude;
    final lng1 = _boundsSW!.longitude;
    final lat2 = coordinates.latitude;
    final lng2 = coordinates.longitude;

    final sw = LatLng(
      lat1 < lat2 ? lat1 : lat2,
      lng1 < lng2 ? lng1 : lng2,
    );
    final ne = LatLng(
      lat1 > lat2 ? lat1 : lat2,
      lng1 > lng2 ? lng1 : lng2,
    );

    // Reject selections that cross the antimeridian (lon span > 180°).
    // The SW/NE min-max normalization above silently inverts such boxes
    // into a ~357° wide region, which explodes tile count and MapLibre
    // would refuse anyway.
    if ((ne.longitude - sw.longitude).abs() > 180) {
      setState(() {
        _error = 'Selected region crosses the antimeridian. '
            'Split into two regions (one per hemisphere).';
        _boundsSW = null;
        _boundsNE = null;
        _tapCount = 0;
        _clearBoundsOverlay();
      });
      return;
    }

    setState(() {
      _boundsSW = sw;
      _boundsNE = ne;
      _tapCount = 2;
      _error = null;
      _drawBoundsOverlay();
    });
  }

  void _resetBounds() {
    _clearBoundsOverlay();
    setState(() {
      _boundsSW = null;
      _boundsNE = null;
      _tapCount = 0;
    });
  }

  /// Draw outlines for all previously downloaded regions so the user
  /// can see existing coverage while selecting a new area.
  Future<void> _drawExistingRegions() async {
    if (_mapController == null) return;
    final service = context.read<OfflineMapService>();
    for (final region in service.regions) {
      try {
        final sw = region.bounds.southwest;
        final ne = region.bounds.northeast;
        final nw = LatLng(ne.latitude, sw.longitude);
        final se = LatLng(sw.latitude, ne.longitude);
        final ring = [sw, se, ne, nw, sw];

        final fill = await _mapController!.addFill(FillOptions(
          geometry: [ring],
          fillColor: '#F59E0B', // amber-500
          fillOpacity: 0.10,
        ));
        final line = await _mapController!.addLine(LineOptions(
          geometry: ring,
          lineColor: '#F59E0B',
          lineWidth: 1.5,
          lineOpacity: 0.6,
        ));
        _existingFills.add(fill);
        _existingLines.add(line);
      } catch (e) {
        debugWarn(
            '[OFFLINE_MAP] Failed to draw existing region ${region.name}: $e');
      }
    }
  }

  Future<void> _clearExistingRegions() async {
    if (_mapController == null) return;
    for (final f in _existingFills) {
      try {
        await _mapController!.removeFill(f);
      } catch (_) {}
    }
    for (final l in _existingLines) {
      try {
        await _mapController!.removeLine(l);
      } catch (_) {}
    }
    _existingFills.clear();
    _existingLines.clear();
  }

  void _toggleExistingRegions() {
    setState(() => _showExisting = !_showExisting);
    if (_showExisting) {
      _drawExistingRegions();
    } else {
      _clearExistingRegions();
    }
  }

  Future<void> _drawBoundsOverlay() async {
    if (_mapController == null || _boundsSW == null || _boundsNE == null) {
      return;
    }

    final sw = _boundsSW!;
    final ne = _boundsNE!;
    final nw = LatLng(ne.latitude, sw.longitude);
    final se = LatLng(sw.latitude, ne.longitude);
    final ring = [sw, se, ne, nw, sw];

    try {
      _boundsFill = await _mapController!.addFill(FillOptions(
        geometry: [ring],
        fillColor: '#4A90D9',
        fillOpacity: 0.15,
      ));
      _boundsLine = await _mapController!.addLine(LineOptions(
        geometry: ring,
        lineColor: '#4A90D9',
        lineWidth: 2.0,
        lineOpacity: 0.8,
      ));
    } catch (e) {
      debugWarn('[OFFLINE_MAP] Failed to draw bounds overlay: $e');
    }
  }

  Future<void> _clearBoundsOverlay() async {
    if (_mapController == null) return;
    try {
      if (_boundsFill != null) {
        await _mapController!.removeFill(_boundsFill!);
        _boundsFill = null;
      }
      if (_boundsLine != null) {
        await _mapController!.removeLine(_boundsLine!);
        _boundsLine = null;
      }
    } catch (e) {
      debugWarn('[OFFLINE_MAP] Failed to clear bounds overlay: $e');
    }
  }

  Future<void> _startDownload() async {
    final bounds = _selectedBounds;
    if (bounds == null) return;

    final name = _nameController.text.trim();
    if (name.isEmpty) return;

    final service = context.read<OfflineMapService>();
    final styleUrl = _downloadStyles[_selectedStyle]!;

    // Check storage limit
    final estBytes = OfflineMapService.estimateSizeBytes(_estimatedTiles);
    if (service.wouldExceedLimit(estBytes)) {
      setState(() {
        _error = 'This download would exceed your storage limit. '
            'Free up space or increase the limit in storage settings.';
      });
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    // Await the service call. downloadRegion returns once the native
    // downloader has accepted (or rejected) the job — actual tile fetches
    // continue in the background after this returns. If validation fails
    // (quota, free-space, style, antimeridian, etc.), lastError is set and
    // isDownloading is false; otherwise the download is queued.
    await service.downloadRegion(
      name: name,
      bounds: bounds,
      styleUrl: styleUrl,
      styleName: _selectedStyle,
      minZoom: _minZoom,
      maxZoom: _maxZoom,
    );

    if (!mounted) return;

    if (!service.isDownloading && service.lastError != null) {
      setState(() {
        _submitting = false;
        _error = service.consumeLastError();
      });
      return;
    }
    // Download is queued — return to the management screen.
    Navigator.pop(context, true);
  }
}
