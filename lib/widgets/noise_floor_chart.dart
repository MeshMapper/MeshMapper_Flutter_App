import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/noise_floor_session.dart';
import '../providers/app_state_provider.dart';
import '../utils/ping_colors.dart';
import 'repeater_id_chip.dart';

/// Interactive noise floor chart with pinch-to-zoom and pan
class InteractiveNoiseFloorChart extends StatefulWidget {
  final NoiseFloorSession session;
  final bool isLive;

  const InteractiveNoiseFloorChart(
      {super.key, required this.session, this.isLive = false});

  @override
  State<InteractiveNoiseFloorChart> createState() =>
      InteractiveNoiseFloorChartState();
}

class InteractiveNoiseFloorChartState
    extends State<InteractiveNoiseFloorChart> {
  // View window in seconds
  late double _viewStart;
  late double _viewEnd;
  late double _totalDuration;

  // Gesture state
  double? _gestureStartViewStart;
  double? _gestureStartViewEnd;
  double? _gestureStartFocalX;

  // Cached line data - only rebuild when session changes, not during zoom
  LineChartBarData? _cachedLineData;
  NoiseFloorSession? _cachedSession;
  int _cachedSampleCount = 0;

  static const double _minVisibleSeconds = 10.0;
  static const double _markerTapRadius = 20.0; // Tap target radius for markers

  @override
  void initState() {
    super.initState();
    _initView();
  }

  @override
  void didUpdateWidget(InteractiveNoiseFloorChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      _initView();
      _cachedLineData = null;
      _cachedSession = null;
      _cachedSampleCount = 0;
    } else if (widget.isLive) {
      _updateLiveView();
    }
  }

  void _initView() {
    _totalDuration = widget.session.duration.inSeconds.toDouble();
    if (_totalDuration < 60) _totalDuration = 60;
    _viewStart = 0;
    _viewEnd = _totalDuration;
  }

  void _updateLiveView() {
    final newTotal = widget.session.duration.inSeconds.toDouble();
    final effectiveTotal = newTotal < 60 ? 60.0 : newTotal;

    // Detect if user is at full (unzoomed) view: start near 0 and end near total
    final isFullView =
        _viewStart < 2.0 && (_totalDuration - _viewEnd).abs() < 2.0;

    _totalDuration = effectiveTotal;

    if (isFullView) {
      // Follow new data
      _viewStart = 0;
      _viewEnd = _totalDuration;
    }
    // If user has zoomed, leave their view window alone
  }

  void resetZoom() {
    setState(() {
      _totalDuration = widget.session.duration.inSeconds.toDouble();
      if (_totalDuration < 60) _totalDuration = 60;
      _viewStart = 0;
      _viewEnd = _totalDuration;
    });
  }

  double get _visibleDuration => _viewEnd - _viewStart;
  double get _zoomLevel => _totalDuration / _visibleDuration;

  void _handleScaleStart(
      ScaleStartDetails details, double chartWidth, double chartLeft) {
    _gestureStartViewStart = _viewStart;
    _gestureStartViewEnd = _viewEnd;
    _gestureStartFocalX = details.localFocalPoint.dx;
  }

  void _handleScaleUpdate(
      ScaleUpdateDetails details, double chartWidth, double chartLeft) {
    if (_gestureStartViewStart == null ||
        _gestureStartViewEnd == null ||
        _gestureStartFocalX == null) {
      return;
    }

    final startDuration = _gestureStartViewEnd! - _gestureStartViewStart!;

    // Calculate new duration based on scale (zoom)
    var newDuration = startDuration / details.scale;
    newDuration = newDuration.clamp(_minVisibleSeconds, _totalDuration);

    // Calculate focal point ratio in chart space
    final focalRatio =
        ((_gestureStartFocalX! - chartLeft) / chartWidth).clamp(0.0, 1.0);

    // Time at focal point in original view
    final focalTime = _gestureStartViewStart! + (startDuration * focalRatio);

    // Calculate pan offset from focal point movement
    final focalDeltaX = details.localFocalPoint.dx - _gestureStartFocalX!;
    final panSeconds = (focalDeltaX / chartWidth) * startDuration;

    // New view: zoom centered on focal point, then apply pan
    var newStart = focalTime - (newDuration * focalRatio) - panSeconds;
    var newEnd = newStart + newDuration;

    // Clamp to valid bounds
    if (newStart < 0) {
      newEnd = newEnd - newStart;
      newStart = 0;
    }
    if (newEnd > _totalDuration) {
      newStart = newStart - (newEnd - _totalDuration);
      newEnd = _totalDuration;
    }

    // Final clamp
    newStart = newStart.clamp(0.0, _totalDuration - newDuration);
    newEnd = (newStart + newDuration).clamp(newDuration, _totalDuration);

    setState(() {
      _viewStart = newStart;
      _viewEnd = newEnd;
    });
  }

  void _handleScaleEnd(ScaleEndDetails details) {
    _gestureStartViewStart = null;
    _gestureStartViewEnd = null;
    _gestureStartFocalX = null;
  }

  /// Check if tap hit a marker and show popup if so
  void _handleTap(TapUpDetails details, double chartWidth, double chartLeft,
      double chartHeight, double chartTop) {
    final session = widget.session;
    if (session.markers.isEmpty || session.samples.isEmpty) return;

    final range = session.noiseFloorRange;
    final visibleRange = _viewEnd - _viewStart;

    if (visibleRange <= 0 || chartWidth <= 0 || chartHeight <= 0) return;

    // Find if tap is within any marker
    for (final marker in session.markers) {
      final elapsed =
          marker.timestamp.difference(session.startTime).inSeconds.toDouble();

      if (elapsed < _viewStart || elapsed > _viewEnd) continue;

      final noiseFloorOnLine = _interpolateNoiseFloor(elapsed, session);

      final xRatio = (elapsed - _viewStart) / visibleRange;
      final yRatio = (noiseFloorOnLine - range.min) / (range.max - range.min);

      final markerX = chartLeft + (xRatio * chartWidth);
      final markerY = chartTop + chartHeight - (yRatio * chartHeight);

      final tapX = details.localPosition.dx;
      final tapY = details.localPosition.dy;

      final distance = ((tapX - markerX) * (tapX - markerX) +
          (tapY - markerY) * (tapY - markerY));
      if (distance <= _markerTapRadius * _markerTapRadius) {
        _showMarkerDetails(marker, noiseFloorOnLine.round());
        return;
      }
    }
  }

  /// Interpolate noise floor at given elapsed time
  double _interpolateNoiseFloor(
      double elapsedSeconds, NoiseFloorSession session) {
    if (session.samples.isEmpty) {
      return widget.session.noiseFloorRange.min.toDouble();
    }
    if (session.samples.length == 1) {
      return session.samples.first.noiseFloor.toDouble();
    }

    NoiseFloorSample? before;
    NoiseFloorSample? after;
    double beforeElapsed = 0;
    double afterElapsed = 0;

    for (final sample in session.samples) {
      final sampleElapsed =
          sample.timestamp.difference(session.startTime).inSeconds.toDouble();

      if (sampleElapsed <= elapsedSeconds) {
        before = sample;
        beforeElapsed = sampleElapsed;
      } else {
        after = sample;
        afterElapsed = sampleElapsed;
        break;
      }
    }

    if (before == null) return session.samples.first.noiseFloor.toDouble();
    if (after == null) return before.noiseFloor.toDouble();

    final timeFraction =
        (elapsedSeconds - beforeElapsed) / (afterElapsed - beforeElapsed);
    return before.noiseFloor +
        (after.noiseFloor - before.noiseFloor) * timeFraction;
  }

  /// Show marker details popup as a modern bottom sheet
  void _showMarkerDetails(PingEventMarker marker, int interpolatedNoiseFloor) {
    final eventTypeLabel = switch (marker.type) {
      PingEventType.txSuccess => 'TX Success',
      PingEventType.txFail => 'TX Failed',
      PingEventType.rx => 'RX Received',
      PingEventType.discSuccess => 'Discovery Success',
      PingEventType.discFail => 'Discovery Failed',
      PingEventType.traceSuccess => 'Trace Success',
      PingEventType.traceFail => 'Trace Failed',
    };

    final eventDescription = switch (marker.type) {
      PingEventType.txSuccess => 'Ping was heard by repeater(s)',
      PingEventType.txFail => 'Ping was not heard by any repeater',
      PingEventType.rx => 'Received passive observation',
      PingEventType.discSuccess => 'Discovery got response',
      PingEventType.discFail => 'Discovery got no response',
      PingEventType.traceSuccess => 'Trace got response from target',
      PingEventType.traceFail => 'Trace got no response from target',
    };

    final hasLocation = marker.latitude != null && marker.longitude != null;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Drag handle
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurfaceVariant
                          .withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Header with event type
                Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: marker.color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      eventTypeLabel,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const Spacer(),
                    Text(
                      _formatTimestamp(marker.timestamp),
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  eventDescription,
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),

                const SizedBox(height: 16),

                // Info cards row
                Row(
                  children: [
                    Expanded(
                      child: _buildInfoCard(
                        context,
                        icon: Icons.graphic_eq,
                        label: 'Noise Floor',
                        value: '$interpolatedNoiseFloor dBm',
                      ),
                    ),
                    if (hasLocation) ...[
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildInfoCard(
                          context,
                          icon: Icons.location_on,
                          label: 'Location',
                          value:
                              '${marker.latitude!.toStringAsFixed(4)}, ${marker.longitude!.toStringAsFixed(4)}',
                          compact: true,
                        ),
                      ),
                    ],
                  ],
                ),

                // Repeaters section (table format like TX log)
                if (marker.repeaters != null &&
                    marker.repeaters!.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Container(
                    decoration: BoxDecoration(
                      color:
                          Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: Theme.of(context)
                              .colorScheme
                              .outline
                              .withValues(alpha: 0.5)),
                    ),
                    child: Column(
                      children: [
                        // Header row
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 8),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 50,
                                child: Text(
                                  'Node',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  'SNR',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  'RSSI',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Divider(
                            height: 1, color: Theme.of(context).dividerColor),
                        // Data rows
                        ...marker.repeaters!
                            .map((r) => _buildRepeaterRow(context, r)),
                      ],
                    ),
                  ),
                ],

                // View on Map button
                if (hasLocation) ...[
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () {
                        // Get references before popping
                        final appState = Provider.of<AppStateProvider>(context,
                            listen: false);
                        final navigator = Navigator.of(context);

                        // Pop the bottom sheet first
                        navigator.pop();

                        // Pop back to main scaffold (removes the full-screen graph page)
                        // Use popUntil to ensure we get back to the root
                        navigator.popUntil((route) => route.isFirst);

                        // Navigate to map and center on location
                        appState.navigateToMapCoordinates(
                            marker.latitude!, marker.longitude!);
                      },
                      icon: const Icon(Icons.map, size: 18),
                      label: const Text('View on Map'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Build info card for the bottom sheet
  Widget _buildInfoCard(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    bool compact = false,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: 14,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: compact ? 11 : 14,
              fontWeight: FontWeight.w600,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  /// Build a table row for a repeater (matching TX log style)
  Widget _buildRepeaterRow(BuildContext context, MarkerRepeaterInfo repeater) {
    final snrColor = PingColors.snrColor(repeater.snr);
    final rssiColor = PingColors.rssiColor(repeater.rssi);

    return InkWell(
      onTap: () => RepeaterIdChip.showRepeaterPopup(
          context, repeater.repeaterId,
          fullHexId: repeater.pubkeyHex),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            // Node ID
            RepeaterIdChip(
                repeaterId: repeater.repeaterId, fontSize: 11, width: 50),
            // SNR chip
            Expanded(
              child: Center(
                child:
                    _buildValueChip(repeater.snr.toStringAsFixed(1), snrColor),
              ),
            ),
            // RSSI chip
            Expanded(
              child: Center(
                child: _buildValueChip('${repeater.rssi}', rssiColor),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Build a small colored chip for table cells
  Widget _buildValueChip(String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        value,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
          fontFamily: 'monospace',
        ),
      ),
    );
  }

  String _formatTimestamp(DateTime dt) {
    return '${dt.hour}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;

    if (session.samples.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.show_chart,
              size: 48,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 8),
            Text(
              'No data recorded',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    final range = session.noiseFloorRange;

    // Chart layout constants
    const leftPadding = 44.0;
    const rightPadding = 16.0;
    const topPadding = 8.0;

    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final chartWidth =
                  constraints.maxWidth - leftPadding - rightPadding;

              final chartHeight = constraints.maxHeight -
                  topPadding -
                  36.0; // 36 = bottom axis reserved

              return RawGestureDetector(
                gestures: <Type, GestureRecognizerFactory>{
                  ScaleGestureRecognizer: GestureRecognizerFactoryWithHandlers<
                      ScaleGestureRecognizer>(
                    () => ScaleGestureRecognizer(),
                    (ScaleGestureRecognizer instance) {
                      instance.onStart = (details) =>
                          _handleScaleStart(details, chartWidth, leftPadding);
                      instance.onUpdate = (details) =>
                          _handleScaleUpdate(details, chartWidth, leftPadding);
                      instance.onEnd = _handleScaleEnd;
                    },
                  ),
                  TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<
                      TapGestureRecognizer>(
                    () => TapGestureRecognizer(),
                    (TapGestureRecognizer instance) {
                      instance.onTapUp = (details) => _handleTap(details,
                          chartWidth, leftPadding, chartHeight, topPadding);
                    },
                  ),
                },
                behavior: HitTestBehavior.opaque,
                child: Stack(
                  children: [
                    // Line chart - wrapped in IgnorePointer so it doesn't steal gestures
                    Padding(
                      padding: const EdgeInsets.only(
                          top: topPadding, right: rightPadding),
                      child: IgnorePointer(
                        child: LineChart(
                          LineChartData(
                            minY: range.min.toDouble(),
                            maxY: range.max.toDouble(),
                            minX: _viewStart,
                            maxX: _viewEnd,
                            clipData: const FlClipData.all(),
                            lineBarsData: [_buildLineData(session)],
                            lineTouchData: const LineTouchData(enabled: false),
                            titlesData: _buildTitles(context),
                            gridData: _buildGrid(context),
                            borderData: _buildBorder(context),
                          ),
                          duration: Duration.zero,
                        ),
                      ),
                    ),
                    // Marker overlay
                    Padding(
                      padding: const EdgeInsets.only(
                          top: topPadding, right: rightPadding),
                      child: IgnorePointer(
                        child: CustomPaint(
                          size: Size.infinite,
                          painter: _MarkerPainter(
                            session: session,
                            minY: range.min.toDouble(),
                            maxY: range.max.toDouble(),
                            minX: _viewStart,
                            maxX: _viewEnd,
                            markerCount: session.markers.length,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 4),
        // Zoom indicator
        if (_zoomLevel > 1.05)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '${_zoomLevel.toStringAsFixed(1)}x  •  ${_formatDuration(Duration(seconds: _viewStart.toInt()))} – ${_formatDuration(Duration(seconds: _viewEnd.toInt()))}',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        _buildLegend(context),
      ],
    );
  }

  LineChartBarData _buildLineData(NoiseFloorSession session) {
    // Return cached data if session hasn't changed (prevents rebuilding during zoom)
    if (_cachedLineData != null &&
        _cachedSession == session &&
        _cachedSampleCount == session.samples.length) {
      return _cachedLineData!;
    }

    final spots = session.samples.map((s) {
      final elapsed =
          s.timestamp.difference(session.startTime).inSeconds.toDouble();
      return FlSpot(elapsed, s.noiseFloor.toDouble());
    }).toList();

    final range = session.noiseFloorRange;
    final minY = range.min.toDouble();
    final maxY = range.max.toDouble();
    final yRange = maxY - minY;

    // Calculate gradient stops based on noise floor thresholds
    // Green: -120 to -100 (good), Orange: -100 to -90 (medium), Red: -90+ (bad)
    double yToStop(double dbm) {
      if (yRange <= 0) return 0.5;
      return ((dbm - minY) / yRange).clamp(0.0, 1.0);
    }

    // Smooth gradient with faded transitions (palette-aware)
    final lineColors = [
      PingColors.noiseFloorGood,
      PingColors.noiseFloorGood,
      PingColors.noiseFloorMedium,
      PingColors.noiseFloorBad,
      PingColors.noiseFloorBad,
    ];
    final fillColors = [
      PingColors.noiseFloorGood.withValues(alpha: 0.2),
      PingColors.noiseFloorGood.withValues(alpha: 0.15),
      PingColors.noiseFloorMedium.withValues(alpha: 0.12),
      PingColors.noiseFloorBad.withValues(alpha: 0.1),
      PingColors.noiseFloorBad.withValues(alpha: 0.08),
    ];
    final stops = [
      0.0,
      yToStop(-100), // Start fading from green
      yToStop(-90), // Orange in middle
      yToStop(-80), // Fade to red
      1.0,
    ];

    _cachedLineData = LineChartBarData(
      spots: spots,
      isCurved: true,
      curveSmoothness: 0.2,
      gradient: LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: lineColors,
        stops: stops,
      ),
      barWidth: 2,
      dotData: const FlDotData(show: false),
      belowBarData: BarAreaData(
        show: true,
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: fillColors,
          stops: stops,
        ),
      ),
    );
    _cachedSession = session;
    _cachedSampleCount = session.samples.length;

    return _cachedLineData!;
  }

  FlTitlesData _buildTitles(BuildContext context) {
    final xInterval = _calculateInterval(_visibleDuration);

    return FlTitlesData(
      bottomTitles: AxisTitles(
        axisNameWidget: Text(
          'Elapsed Time',
          style: TextStyle(
            fontSize: 10,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        sideTitles: SideTitles(
          showTitles: true,
          interval: xInterval,
          reservedSize: 28,
          getTitlesWidget: (value, meta) {
            if (value <= _viewStart || value >= _viewEnd) {
              return const SizedBox.shrink();
            }
            final elapsed = Duration(seconds: value.toInt());
            return Text(
              _formatDuration(elapsed),
              style: TextStyle(
                fontSize: 10,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            );
          },
        ),
      ),
      leftTitles: AxisTitles(
        axisNameWidget: Text(
          'dBm',
          style: TextStyle(
            fontSize: 10,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        sideTitles: SideTitles(
          showTitles: true,
          interval: 10,
          reservedSize: 36,
          getTitlesWidget: (value, meta) {
            return Text(
              '${value.toInt()}',
              style: TextStyle(
                fontSize: 10,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            );
          },
        ),
      ),
      topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
    );
  }

  FlGridData _buildGrid(BuildContext context) {
    return FlGridData(
      show: true,
      drawHorizontalLine: true,
      drawVerticalLine: true,
      horizontalInterval: 10,
      getDrawingHorizontalLine: (value) {
        return FlLine(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
          strokeWidth: 1,
        );
      },
      getDrawingVerticalLine: (value) {
        return FlLine(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
          strokeWidth: 1,
        );
      },
    );
  }

  FlBorderData _buildBorder(BuildContext context) {
    return FlBorderData(
      show: true,
      border: Border.all(
        color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5),
      ),
    );
  }

  Widget _buildLegend(BuildContext context) {
    return Wrap(
      spacing: 16,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: [
        _legendItem(context, PingColors.txSuccess, 'TX Success'),
        _legendItem(context, PingColors.txFail, 'TX Fail'),
        _legendItem(context, PingColors.rx, 'RX'),
        _legendItem(context, PingColors.discSuccess, 'DISC Success'),
        _legendItem(context, PingColors.traceSuccess, 'Trace Success'),
        _legendItem(context, PingColors.noResponse, 'No Response'),
      ],
    );
  }

  Widget _legendItem(BuildContext context, Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 1),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  double _calculateInterval(double visibleRange) {
    if (visibleRange <= 20) return 5;
    if (visibleRange <= 60) return 10;
    if (visibleRange <= 120) return 20;
    if (visibleRange <= 300) return 60;
    if (visibleRange <= 600) return 120;
    if (visibleRange <= 1800) return 300;
    return 600;
  }

  String _formatDuration(Duration d) {
    if (d.inHours > 0) {
      return '${d.inHours}:${(d.inMinutes % 60).toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
    }
    return '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  }
}

/// Custom painter to draw ping event markers on top of the chart
class _MarkerPainter extends CustomPainter {
  final NoiseFloorSession session;
  final double minY;
  final double maxY;
  final double minX;
  final double maxX;
  final int markerCount;

  _MarkerPainter({
    required this.session,
    required this.minY,
    required this.maxY,
    required this.minX,
    required this.maxX,
    required this.markerCount,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (session.markers.isEmpty || session.samples.isEmpty) return;

    const leftPadding = 44.0;
    const bottomPadding = 36.0;
    const topPadding = 0.0;
    const rightPadding = 0.0;

    final chartWidth = size.width - leftPadding - rightPadding;
    final chartHeight = size.height - bottomPadding - topPadding;
    final visibleRange = maxX - minX;

    if (visibleRange <= 0 || chartWidth <= 0 || chartHeight <= 0) return;

    for (final marker in session.markers) {
      final elapsed =
          marker.timestamp.difference(session.startTime).inSeconds.toDouble();

      if (elapsed < minX || elapsed > maxX) continue;

      final noiseFloorOnLine = _interpolateNoiseFloor(elapsed);

      final xRatio = (elapsed - minX) / visibleRange;
      final yRatio = (noiseFloorOnLine - minY) / (maxY - minY);

      final x = leftPadding + (xRatio * chartWidth);
      final y = topPadding + chartHeight - (yRatio * chartHeight);

      final paint = Paint()
        ..color = marker.color
        ..style = PaintingStyle.fill;

      canvas.drawCircle(Offset(x, y), 6, paint);

      final borderPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;

      canvas.drawCircle(Offset(x, y), 6, borderPaint);
    }
  }

  double _interpolateNoiseFloor(double elapsedSeconds) {
    if (session.samples.isEmpty) return minY;
    if (session.samples.length == 1) {
      return session.samples.first.noiseFloor.toDouble();
    }

    NoiseFloorSample? before;
    NoiseFloorSample? after;
    double beforeElapsed = 0;
    double afterElapsed = 0;

    for (final sample in session.samples) {
      final sampleElapsed =
          sample.timestamp.difference(session.startTime).inSeconds.toDouble();

      if (sampleElapsed <= elapsedSeconds) {
        before = sample;
        beforeElapsed = sampleElapsed;
      } else {
        after = sample;
        afterElapsed = sampleElapsed;
        break;
      }
    }

    if (before == null) return session.samples.first.noiseFloor.toDouble();
    if (after == null) return before.noiseFloor.toDouble();

    final timeFraction =
        (elapsedSeconds - beforeElapsed) / (afterElapsed - beforeElapsed);
    return before.noiseFloor +
        (after.noiseFloor - before.noiseFloor) * timeFraction;
  }

  @override
  bool shouldRepaint(covariant _MarkerPainter oldDelegate) {
    return oldDelegate.markerCount != markerCount ||
        oldDelegate.minY != minY ||
        oldDelegate.maxY != maxY ||
        oldDelegate.minX != minX ||
        oldDelegate.maxX != maxX;
  }
}

/// Simple chart wrapper for compatibility
class NoiseFloorChart extends StatelessWidget {
  final NoiseFloorSession session;

  const NoiseFloorChart({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    return InteractiveNoiseFloorChart(session: session);
  }
}
