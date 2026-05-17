# Focus Mode Minimize Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow users to minimize the focus mode ping details popup to a compact pill, giving full map zoom/pan access while keeping focus lines visible.

**Architecture:** All changes are in `lib/widgets/map_widget.dart`. Two new state fields (`_focusPanelMinimized`, `_focusedPingSource`) track minimized state. The 4 existing `_show*Details` methods gain a minimize button and `fromMinimized` parameter. A new `_buildMinimizedFocusPanel()` method renders the pill in the map's outer `Stack`. `_activatePingFocus` and `_dismissPingFocus` are updated to manage the new state.

**Tech Stack:** Flutter, MapLibre GL, Provider

---

### Task 1: Add state fields and update `_activatePingFocus`

**Files:**
- Modify: `lib/widgets/map_widget.dart:382` (state fields)
- Modify: `lib/widgets/map_widget.dart:5357-5413` (`_activatePingFocus`)

- [ ] **Step 1: Add new state fields**

After line 382 (`bool _wasRotatingBeforeFocus = false;`), add:

```dart
  bool _focusPanelMinimized = false;
  dynamic _focusedPingSource; // TxPing | RxPing | DiscLogEntry | TraceLogEntry
```

- [ ] **Step 2: Update `_activatePingFocus` to handle re-activation**

Replace the entire `_activatePingFocus` method (lines 5357-5413) with:

```dart
  void _activatePingFocus(LatLng pingLocation, DateTime timestamp,
      List<_ResolvedRepeater> repeaters) {
    // Drop repeaters lacking GPS — they would draw lines off to (0, 0).
    // The bottom-sheet row builder still surfaces them with a no-location
    // icon. If nothing is left to focus on, skip activation entirely so
    // the user's current map view (zoom, autofollow, rotation) is kept.
    final located =
        repeaters.where((r) => r.repeater.hasLocation).toList(growable: false);
    if (located.isEmpty) return;

    // Only save pre-focus state on first activation. When re-activating
    // (e.g. user taps a different ping while already in focus, or expanding
    // from minimized), we keep the original pre-focus snapshot so dismiss
    // restores the correct camera position.
    final alreadyInFocus = _focusedPingLocation != null;
    if (!alreadyInFocus) {
      final pos = _mapController?.cameraPosition;
      _preFocusCenter = pos?.target;
      _preFocusZoom = pos?.zoom;
      _wasAutoFollowBeforeFocus = _autoFollow;
      _wasRotatingBeforeFocus = !_alwaysNorth;

      if (_autoFollow) {
        _autoFollow = false;
      }

      // Lock to north-up during focus so the zoom-to-fit view is stable
      if (!_alwaysNorth) {
        _alwaysNorth = true;
        // Snap rotation to north (instant — avoids wobble before zoom-to-fit animation)
        if (_isMapReady && _mapController != null && _canAnimateCamera) {
          _mapController!.animateCamera(
            CameraUpdate.bearingTo(0),
            duration: const Duration(milliseconds: 1),
          );
        }
      }
    }

    _focusPanelMinimized = false;

    setState(() {
      _focusedPingLocation = pingLocation;
      _focusedPingTimestamp = timestamp;
      _focusedRepeaters = located;
    });

    // Hide the MeshMapper coverage raster overlay for a clean focus view.
    // Uses opacity=0 rather than removing the layer to avoid a tile refetch
    // on dismiss. No-ops gracefully if the layer isn't present.
    _applyCoverageOverlayOpacity(0.0);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _focusedPingLocation != null) {
        _zoomToFocusBounds(pingLocation, located);
      }
    });

    // Once the 500ms zoom-to-fit animation settles, re-flow the distance
    // labels so any that collide on screen slide along their lines to a
    // non-overlapping slot. 600ms gives the camera a bit of buffer beyond
    // the animation duration.
    Future.delayed(const Duration(milliseconds: 600), () {
      if (!mounted || _focusedPingLocation == null) return;
      _reflowDistanceLabelsForCollisions();
    });
  }
```

- [ ] **Step 3: Verify no syntax errors**

Run: `flutter analyze lib/widgets/map_widget.dart`
Expected: No new errors (existing warnings are OK)

- [ ] **Step 4: Commit**

```bash
git add lib/widgets/map_widget.dart
git commit -m "feat: add focus panel state fields and update _activatePingFocus for re-activation"
```

---

### Task 2: Update `_dismissPingFocus` to clear new state

**Files:**
- Modify: `lib/widgets/map_widget.dart:5417-5461` (`_dismissPingFocus`)

- [ ] **Step 1: Update `_dismissPingFocus`**

Replace lines 5417-5461 (the full `_dismissPingFocus` method) with:

```dart
  void _dismissPingFocus() {
    if (_focusedPingLocation == null || !mounted) return;

    final center = _preFocusCenter;
    final zoom = _preFocusZoom;
    final shouldRestoreAutoFollow = _wasAutoFollowBeforeFocus && !_autoFollow;
    final shouldRestoreRotation = _wasRotatingBeforeFocus && _alwaysNorth;

    // Clear focus state but do NOT restore auto-follow or rotation yet —
    // they would immediately trigger animations in the build method that
    // override our zoom-back animation (both share _animationController).
    setState(() {
      _focusedPingLocation = null;
      _focusedPingTimestamp = null;
      _focusedRepeaters = [];
      _focusPanelMinimized = false;
      _focusedPingSource = null;
    });

    // Restore the MeshMapper coverage raster overlay opacity. Safe if the
    // layer was hidden via the toggle during focus — setLayerProperties is
    // wrapped in try/catch inside the helper.
    final appState = context.read<AppStateProvider>();
    _applyCoverageOverlayOpacity(appState.preferences.coverageOverlayOpacity);

    if (center != null && zoom != null) {
      _animateToPositionWithZoom(center, zoom);

      // Restore auto-follow and heading rotation after the zoom-back
      // animation completes (500ms) so they don't clobber it mid-flight.
      if (shouldRestoreAutoFollow || shouldRestoreRotation) {
        Future.delayed(const Duration(milliseconds: 550), () {
          if (mounted) {
            setState(() {
              if (shouldRestoreAutoFollow) _autoFollow = true;
              if (shouldRestoreRotation) _alwaysNorth = false;
            });
          }
        });
      }
    } else {
      setState(() {
        if (shouldRestoreAutoFollow) _autoFollow = true;
        if (shouldRestoreRotation) _alwaysNorth = false;
      });
    }
  }
```

- [ ] **Step 2: Verify no syntax errors**

Run: `flutter analyze lib/widgets/map_widget.dart`
Expected: No new errors

- [ ] **Step 3: Commit**

```bash
git add lib/widgets/map_widget.dart
git commit -m "feat: update _dismissPingFocus to clear minimized state"
```

---

### Task 3: Add minimize button to `_showTxPingDetails` and change completion handler

**Files:**
- Modify: `lib/widgets/map_widget.dart:5582-5908` (`_showTxPingDetails`)

- [ ] **Step 1: Add `fromMinimized` parameter and store ping source**

Replace the method signature and pre-sheet logic (lines 5582-5599):

```dart
  void _showTxPingDetails(TxPing ping, {bool fromMinimized = false}) {
    // Use the heardRepeaters directly from the TxPing
    final heardRepeaters = ping.heardRepeaters;

    // Resolve repeater matches (hoisted so bottom sheet can check ambiguity)
    final resolved = heardRepeaters.isNotEmpty
        ? _resolveRepeatersByHexIds(
            heardRepeaters.map((r) => r.repeaterId).toList(),
            snrValues: heardRepeaters.map((r) => r.snr).toList(),
          )
        : <_ResolvedRepeater>[];
    final hasAmbiguous = resolved.any((r) => r.ambiguous);

    _focusedPingSource = ping;

    // Activate focus mode if the ping was heard by known repeaters
    if (!fromMinimized && resolved.isNotEmpty) {
      _activatePingFocus(
          LatLng(ping.latitude, ping.longitude), ping.timestamp, resolved);
    }
```

- [ ] **Step 2: Add minimize button next to close button in header**

Find the close IconButton in the TX sheet (around line 5665):

```dart
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => Navigator.pop(context),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
```

Replace with:

```dart
                    IconButton(
                      icon: const Icon(Icons.keyboard_arrow_down, size: 20),
                      onPressed: () => Navigator.pop(context, 'minimized'),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      tooltip: 'Minimize',
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => Navigator.pop(context),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
```

- [ ] **Step 3: Change `.whenComplete` to `.then`**

Find (around line 5907):

```dart
    ).whenComplete(() => _dismissPingFocus());
  }
```

(This is the one immediately after the TX sheet builder's closing brackets, before `_showRxPingDetails`.)

Replace with:

```dart
    ).then((result) {
      if (result == 'minimized') {
        setState(() => _focusPanelMinimized = true);
      } else {
        _dismissPingFocus();
      }
    });
  }
```

- [ ] **Step 4: Verify no syntax errors**

Run: `flutter analyze lib/widgets/map_widget.dart`
Expected: No new errors

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/map_widget.dart
git commit -m "feat: add minimize button to TX ping details sheet"
```

---

### Task 4: Add minimize button to `_showRxPingDetails`

**Files:**
- Modify: `lib/widgets/map_widget.dart:5911-6193` (`_showRxPingDetails`)

- [ ] **Step 1: Add `fromMinimized` parameter and store ping source**

Replace the method signature and pre-sheet logic (lines 5911-5923):

```dart
  void _showRxPingDetails(RxPing ping, {bool fromMinimized = false}) {
    final snrColor = PingColors.snrColor(ping.snr);
    final rssiColor = PingColors.rssiColor(ping.rssi);

    // Activate focus mode for the RX ping's repeater
    final resolved = _resolveRepeatersByHexIds(
      [ping.repeaterId],
      snrValues: [ping.snr],
    );

    _focusedPingSource = ping;

    if (!fromMinimized && resolved.isNotEmpty) {
      _activatePingFocus(
          LatLng(ping.latitude, ping.longitude), ping.timestamp, resolved);
    }
```

- [ ] **Step 2: Add minimize button next to close button in header**

Find the close IconButton in the RX sheet (around line 5978):

```dart
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.pop(context),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
```

Replace with:

```dart
                IconButton(
                  icon: const Icon(Icons.keyboard_arrow_down, size: 20),
                  onPressed: () => Navigator.pop(context, 'minimized'),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'Minimize',
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.pop(context),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
```

- [ ] **Step 3: Change `.whenComplete` to `.then`**

Find (around line 6193):

```dart
    ).whenComplete(() => _dismissPingFocus());
  }
```

(This is the one immediately before `_showDiscPingDetails`.)

Replace with:

```dart
    ).then((result) {
      if (result == 'minimized') {
        setState(() => _focusPanelMinimized = true);
      } else {
        _dismissPingFocus();
      }
    });
  }
```

- [ ] **Step 4: Verify no syntax errors**

Run: `flutter analyze lib/widgets/map_widget.dart`
Expected: No new errors

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/map_widget.dart
git commit -m "feat: add minimize button to RX ping details sheet"
```

---

### Task 5: Add minimize button to `_showDiscPingDetails`

**Files:**
- Modify: `lib/widgets/map_widget.dart:6197-6512` (`_showDiscPingDetails`)

- [ ] **Step 1: Add `fromMinimized` parameter and store entry source**

Replace the method signature and pre-sheet logic (lines 6197-6210):

```dart
  void _showDiscPingDetails(DiscLogEntry entry, {bool fromMinimized = false}) {
    // Activate focus mode for discovered nodes with known repeater positions
    _focusedPingSource = entry;

    if (!fromMinimized && entry.discoveredNodes.isNotEmpty) {
      final resolved = _resolveRepeatersByHexIds(
        entry.discoveredNodes.map((n) => n.repeaterId).toList(),
        fullHexIds: entry.discoveredNodes.map((n) => n.pubkeyHex).toList(),
        snrValues:
            entry.discoveredNodes.map((n) => n.localSnr as double?).toList(),
      );
      if (resolved.isNotEmpty) {
        _activatePingFocus(
            LatLng(entry.latitude, entry.longitude), entry.timestamp, resolved);
      }
    }
```

- [ ] **Step 2: Add minimize button next to close button in header**

Find the close IconButton in the Disc sheet (around line 6276):

```dart
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => Navigator.pop(context),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
```

Replace with:

```dart
                    IconButton(
                      icon: const Icon(Icons.keyboard_arrow_down, size: 20),
                      onPressed: () => Navigator.pop(context, 'minimized'),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      tooltip: 'Minimize',
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => Navigator.pop(context),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
```

- [ ] **Step 3: Change `.whenComplete` to `.then`**

Find (around line 6512):

```dart
    ).whenComplete(() => _dismissPingFocus());
  }
```

(This is the one immediately before `_buildRepeaterStatusChip`.)

Replace with:

```dart
    ).then((result) {
      if (result == 'minimized') {
        setState(() => _focusPanelMinimized = true);
      } else {
        _dismissPingFocus();
      }
    });
  }
```

- [ ] **Step 4: Verify no syntax errors**

Run: `flutter analyze lib/widgets/map_widget.dart`
Expected: No new errors

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/map_widget.dart
git commit -m "feat: add minimize button to Disc ping details sheet"
```

---

### Task 6: Add minimize button to `_showTraceDetails`

**Files:**
- Modify: `lib/widgets/map_widget.dart:4971-5275` (`_showTraceDetails`)

- [ ] **Step 1: Add `fromMinimized` parameter and store entry source**

Replace the method signature and pre-sheet logic (lines 4971-4982):

```dart
  void _showTraceDetails(TraceLogEntry entry, {bool fromMinimized = false}) {
    // Activate focus mode for successful traces with a known repeater
    _focusedPingSource = entry;

    if (!fromMinimized && entry.success) {
      final resolved = _resolveRepeatersByHexIds(
        [entry.targetRepeaterId],
        snrValues: [entry.localSnr],
      );
      if (resolved.isNotEmpty) {
        _activatePingFocus(
            LatLng(entry.latitude, entry.longitude), entry.timestamp, resolved);
      }
    }
```

- [ ] **Step 2: Add minimize button next to close button in header**

Find the close IconButton in the Trace sheet (around line 5047):

```dart
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => Navigator.pop(context),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
```

Replace with:

```dart
                    IconButton(
                      icon: const Icon(Icons.keyboard_arrow_down, size: 20),
                      onPressed: () => Navigator.pop(context, 'minimized'),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      tooltip: 'Minimize',
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => Navigator.pop(context),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
```

- [ ] **Step 3: Change `.whenComplete` to `.then`**

Find (around line 5275):

```dart
    ).whenComplete(() => _dismissPingFocus());
  }
```

(This is the one immediately before `/// DISC marker color`.)

Replace with:

```dart
    ).then((result) {
      if (result == 'minimized') {
        setState(() => _focusPanelMinimized = true);
      } else {
        _dismissPingFocus();
      }
    });
  }
```

- [ ] **Step 4: Verify no syntax errors**

Run: `flutter analyze lib/widgets/map_widget.dart`
Expected: No new errors

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/map_widget.dart
git commit -m "feat: add minimize button to Trace details sheet"
```

---

### Task 7: Add `_buildMinimizedFocusPanel` and `_reshowFocusPanel` methods

**Files:**
- Modify: `lib/widgets/map_widget.dart` (add new methods near `_dismissPingFocus`, around line 5462)

- [ ] **Step 1: Add `_reshowFocusPanel` method**

Insert after the closing brace of `_dismissPingFocus()` (which ends with `}`):

```dart
  void _reshowFocusPanel() {
    setState(() => _focusPanelMinimized = false);
    final source = _focusedPingSource;
    if (source is TxPing) {
      _showTxPingDetails(source, fromMinimized: true);
    } else if (source is RxPing) {
      _showRxPingDetails(source, fromMinimized: true);
    } else if (source is DiscLogEntry) {
      _showDiscPingDetails(source, fromMinimized: true);
    } else if (source is TraceLogEntry) {
      _showTraceDetails(source, fromMinimized: true);
    }
  }
```

- [ ] **Step 2: Add `_buildMinimizedFocusPanel` method**

Insert immediately after `_reshowFocusPanel`:

```dart
  Widget _buildMinimizedFocusPanel() {
    final source = _focusedPingSource;
    String title;
    IconData icon;
    Color color;
    if (source is TxPing) {
      title = 'TX Ping';
      icon = Icons.arrow_upward;
      color = PingColors.txSuccess;
    } else if (source is RxPing) {
      title = 'RX Ping';
      icon = Icons.arrow_downward;
      color = PingColors.rx;
    } else if (source is DiscLogEntry) {
      title = 'Disc Request';
      icon = Icons.radar;
      color = PingColors.discSuccess;
    } else if (source is TraceLogEntry) {
      title = 'Trace';
      icon = Icons.gps_fixed;
      color = Colors.cyan;
    } else {
      return const SizedBox.shrink();
    }

    final repeaterCount = _focusedRepeaters.length;
    final timeStr =
        _focusedPingTimestamp != null ? _formatTime(_focusedPingTimestamp!) : '';

    return GestureDetector(
      onTap: _reshowFocusPanel,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 8),
            Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              timeStr,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            if (repeaterCount > 0) ...[
              const SizedBox(width: 8),
              Text(
                '$repeaterCount repeater${repeaterCount != 1 ? 's' : ''}',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _reshowFocusPanel,
              child: Icon(
                Icons.keyboard_arrow_up,
                size: 20,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: _dismissPingFocus,
              child: Icon(
                Icons.close,
                size: 18,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
```

- [ ] **Step 3: Verify no syntax errors**

Run: `flutter analyze lib/widgets/map_widget.dart`
Expected: No new errors

- [ ] **Step 4: Commit**

```bash
git add lib/widgets/map_widget.dart
git commit -m "feat: add minimized focus panel pill and reshow logic"
```

---

### Task 8: Add minimized pill to the outer Stack in `build()`

**Files:**
- Modify: `lib/widgets/map_widget.dart:1198-1246` (outer Stack in `build()`)

- [ ] **Step 1: Add minimized pill to Stack**

Find the tile load failure banner block (around line 1234-1244):

```dart
        // Tile load failure banner — appears if base tiles haven't finished
        // loading within ${_tileLoadTimeoutSeconds}s after style load.
        if (_tileLoadFailed)
          Positioned(
            top: topPadding,
            left: 0,
            right: 0,
            child: Center(
              child: _buildTileLoadFailedBanner(),
            ),
          ),
      ],
    );
```

Replace with:

```dart
        // Tile load failure banner — appears if base tiles haven't finished
        // loading within ${_tileLoadTimeoutSeconds}s after style load.
        if (_tileLoadFailed)
          Positioned(
            top: topPadding,
            left: 0,
            right: 0,
            child: Center(
              child: _buildTileLoadFailedBanner(),
            ),
          ),

        // Minimized focus panel pill — shown when user minimizes a ping
        // details sheet. Not a modal, so the map underneath stays fully
        // interactable (zoom, pan, rotation).
        if (_focusPanelMinimized && _focusedPingLocation != null)
          Positioned(
            bottom: 16 + MediaQuery.of(context).padding.bottom,
            left: 16,
            right: 16,
            child: Center(
              child: _buildMinimizedFocusPanel(),
            ),
          ),
      ],
    );
```

- [ ] **Step 2: Verify no syntax errors**

Run: `flutter analyze lib/widgets/map_widget.dart`
Expected: No new errors

- [ ] **Step 3: Commit**

```bash
git add lib/widgets/map_widget.dart
git commit -m "feat: render minimized focus pill in map Stack"
```

---

### Task 9: Final verification

**Files:**
- Verify: `lib/widgets/map_widget.dart`

- [ ] **Step 1: Run full static analysis**

Run: `flutter analyze`
Expected: No new errors introduced. Pre-existing warnings are acceptable.

- [ ] **Step 2: Run tests**

Run: `flutter test`
Expected: All existing tests pass.

- [ ] **Step 3: Final commit (squash-friendly message)**

Only if there were any fixups needed from analysis/tests:

```bash
git add lib/widgets/map_widget.dart
git commit -m "fix: address analysis warnings from focus minimize feature"
```
