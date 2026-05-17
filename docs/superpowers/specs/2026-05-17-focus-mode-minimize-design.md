# Focus Mode Minimize

Allow users to minimize the ping details popup during focus mode to get a full map view with zoom/pan access, while keeping focus lines and context visible.

## Current Behavior

When a ping marker is tapped, focus mode activates:
1. `_activatePingFocus()` saves pre-focus camera state, hides unrelated markers/coverage, draws focus lines to repeaters, zooms to fit bounds
2. `showModalBottomSheet()` displays ping details (TX/RX/Disc/Trace variants)
3. The sheet uses `barrierColor: Colors.transparent` — map is visible but the invisible barrier blocks all touch events (no zoom/pan)
4. Closing the sheet (X or swipe-down) calls `_dismissPingFocus()` which restores the pre-focus map state

**Problem:** Users cannot zoom or pan the map while viewing focus lines because the modal barrier intercepts all gestures.

## Design

### Minimize Button in Sheet Header

Each of the 4 detail sheet variants (TX, RX, Disc, Trace) gains a minimize button (down-chevron icon) next to the existing close button:

```
  [↑]  TX Ping          12:34:05  ▽ ✕
```

- `▽` (minimize): closes the sheet but keeps focus mode active → shows minimized pill
- `✕` (close): exits focus mode entirely (unchanged behavior)

### Minimized Pill

A compact, non-modal widget rendered in the map widget's `Stack`:

```
┌──────────────────────────────────────────────┐
│  ↑ TX Ping  12:34:05  3 repeaters   [△] [✕] │
└──────────────────────────────────────────────┘
```

- **Position:** Bottom of map, horizontally centered, above safe area inset
- **Style:** `surfaceContainerHighest` background, rounded corners (12px), subtle border — matches existing sheet theme
- **Content:** Ping type icon (colored), type label, formatted timestamp, repeater count, expand button, close button
- **Behavior:**
  - `△` (expand): re-opens the full details sheet without re-zooming the map
  - `✕` (close): calls `_dismissPingFocus()` to exit focus mode entirely
  - Tapping the pill body also expands (same as △)

### Map Interaction When Minimized

Since the pill is a regular widget in the Stack (not a modal), the map underneath is fully interactable:
- Pinch-to-zoom works
- Pan/drag works
- Rotation works (if rotation lock is off)
- Map control buttons (top-right) remain accessible
- Focus lines and distance labels remain visible

### What Stays the Same

- Full details sheet content (repeater tables, location chip, path chain, etc.)
- Focus activation logic (zoom-to-fit, save pre-focus state, focus lines, coverage hide)
- `_dismissPingFocus()` restore behavior (auto-follow, rotation, zoom-back animation)
- Transparent barrier color on the full sheet when expanded
- Swipe-down on sheet still closes and exits focus (unchanged)

## Implementation Details

### New State in `_MapWidgetState`

```dart
bool _focusPanelMinimized = false;
dynamic _focusedPingSource; // TxPing | RxPing | DiscLogEntry | TraceLogEntry
```

### Modified Methods

**`_activatePingFocus()`:**
- If `_focusedPingLocation != null` (already in focus): skip saving pre-focus state, skip auto-follow/rotation changes — just update the focused ping/repeaters and zoom to new bounds
- Clear `_focusPanelMinimized = false` on activation

**`_dismissPingFocus()`:**
- Additionally clears `_focusPanelMinimized = false` and `_focusedPingSource = null`

**`_show{Tx,Rx,Disc,Trace}Details()`:**
- Store the ping/entry in `_focusedPingSource` before showing the sheet
- Accept optional `{bool fromMinimized = false}` parameter — when true, skip `_activatePingFocus` call (focus is already active)
- Add minimize `IconButton` to header row
- Change `.whenComplete(() => _dismissPingFocus())` to `.then((result) { ... })`:
  - If `result == 'minimized'`: `setState(() => _focusPanelMinimized = true)`
  - Otherwise: `_dismissPingFocus()`

**Minimize button action:** `Navigator.pop(context, 'minimized')`

### New Methods

**`_buildMinimizedFocusPanel()`:**
- Returns the pill widget
- Derives title/icon/color from `_focusedPingSource` runtime type
- Repeater count from `_focusedRepeaters.length`
- Timestamp from `_focusedPingTimestamp`

**`_reshowFocusPanel()`:**
- Checks `_focusedPingSource` type, calls the matching `_show*Details(source, fromMinimized: true)`
- Sets `_focusPanelMinimized = false` via setState

### Build Method Change

In the outer `Stack` (line ~1198), add after map controls:

```dart
if (_focusPanelMinimized && _focusedPingLocation != null)
  Positioned(
    bottom: 16 + MediaQuery.of(context).padding.bottom,
    left: 16,
    right: 16,
    child: _buildMinimizedFocusPanel(),
  ),
```

### Edge Cases

- **User taps a different ping while minimized:** `_handleSymbolTap` calls `_show*Details` for the new ping. `_activatePingFocus` detects existing focus, updates focus state without re-saving pre-focus. The new sheet opens, minimized state is cleared.
- **Auto-reconnect during minimized state:** Disconnect cleanup calls `_dismissPingFocus()` which clears everything including minimized state.
- **Orientation change while minimized:** Pill repositions naturally via `Positioned` + safe area insets.

## Files Modified

- `lib/widgets/map_widget.dart` — all changes are in this single file

## Testing

- Tap TX/RX/Disc/Trace ping → verify minimize button visible in header
- Tap minimize → verify pill appears, map is pannable/zoomable, focus lines stay
- Tap expand on pill → verify full sheet re-opens without re-zooming
- Tap close on pill → verify focus mode fully dismisses, map restores
- While minimized, tap a different ping → verify new focus replaces old
- Swipe-down on full sheet → verify still exits focus mode (unchanged)
