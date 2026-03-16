import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../models/repeater.dart';
import '../providers/app_state_provider.dart';
import '../services/gps_service.dart';
import '../utils/distance_formatter.dart';

/// Show a bottom sheet repeater picker and return the selected repeater.
Future<Repeater?> showRepeaterPicker(BuildContext context) {
  return showModalBottomSheet<Repeater>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (context) => DraggableScrollableSheet(
      initialChildSize: 0.95,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => _RepeaterPickerBody(
        scrollController: scrollController,
      ),
    ),
  );
}

class _RepeaterPickerBody extends StatefulWidget {
  final ScrollController scrollController;

  const _RepeaterPickerBody({required this.scrollController});

  @override
  State<_RepeaterPickerBody> createState() => _RepeaterPickerBodyState();
}

class _RepeaterPickerBodyState extends State<_RepeaterPickerBody> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<Repeater> _filterAndSort(List<Repeater> repeaters, Position? position) {
    List<Repeater> filtered;
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      filtered = repeaters
          .where((r) =>
              r.name.toLowerCase().contains(q) ||
              r.hexId.toLowerCase().startsWith(q))
          .toList();
    } else {
      filtered = List.of(repeaters);
    }

    // Sort: active first, then by distance (if GPS), then alphabetically
    filtered.sort((a, b) {
      // Active first
      if (a.isActive != b.isActive) return a.isActive ? -1 : 1;
      // By distance if GPS available
      if (position != null) {
        final distA = GpsService.distanceBetween(
          position.latitude, position.longitude, a.lat, a.lon,
        );
        final distB = GpsService.distanceBetween(
          position.latitude, position.longitude, b.lat, b.lon,
        );
        return distA.compareTo(distB);
      }
      // Alphabetically
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return filtered;
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    final repeaters = appState.repeaters;
    final position = appState.currentPosition;
    final isImperial = appState.preferences.isImperial;
    final colorScheme = Theme.of(context).colorScheme;

    final filtered = _filterAndSort(repeaters, position);

    return Column(
      children: [
        // Drag handle
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        // Header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.cell_tower, size: 20, color: colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                'Select Repeater',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => Navigator.pop(context),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
        // Search field
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search by name or hex ID...',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _query.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _query = '');
                      },
                    )
                  : null,
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        // Count label
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Showing ${filtered.length} of ${repeaters.length} repeaters',
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        const Divider(height: 1),
        // List
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      repeaters.isEmpty
                          ? 'No repeaters available'
                          : 'No repeaters match your search',
                      style: TextStyle(
                        fontSize: 14,
                        fontStyle: FontStyle.italic,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              : ListView.builder(
                  controller: widget.scrollController,
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final r = filtered[index];
                    return _RepeaterTile(
                      repeater: r,
                      position: position,
                      isImperial: isImperial,
                      onTap: () => Navigator.pop(context, r),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _RepeaterTile extends StatelessWidget {
  final Repeater repeater;
  final Position? position;
  final bool isImperial;
  final VoidCallback onTap;

  const _RepeaterTile({
    required this.repeater,
    required this.position,
    required this.isImperial,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isActive = repeater.isActive;
    final badgeColor = isActive ? Colors.green : Colors.grey;

    // Distance text
    String? distanceText;
    if (position != null) {
      final meters = GpsService.distanceBetween(
        position!.latitude, position!.longitude, repeater.lat, repeater.lon,
      );
      if (meters < 1000) {
        distanceText = formatMeters(meters, isImperial: isImperial);
      } else {
        distanceText =
            formatKilometers(meters / 1000, isImperial: isImperial);
      }
    }

    // Always show 4-byte (8-char) hex ID for identification
    final displayHex = repeater.hexId.length >= 8
        ? repeater.hexId.substring(0, 8).toUpperCase()
        : repeater.hexId.toUpperCase();

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            // Hex badge
            Container(
              constraints: const BoxConstraints(minWidth: 28),
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 5),
              decoration: BoxDecoration(
                color: badgeColor,
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              child: Text(
                displayHex,
                style: TextStyle(
                  fontSize: displayHex.length > 4 ? 8 : 10,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            const SizedBox(width: 12),
            // Name + distance
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    repeater.name,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: colorScheme.onSurface,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (distanceText != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.near_me,
                            size: 10,
                            color: colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            distanceText,
                            style: TextStyle(
                              fontSize: 11,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Active/Stale chip
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: badgeColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
                border:
                    Border.all(color: badgeColor.withValues(alpha: 0.4)),
              ),
              child: Text(
                isActive ? 'Active' : 'Stale',
                style: TextStyle(
                  fontSize: 11,
                  color: badgeColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
