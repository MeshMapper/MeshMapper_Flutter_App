import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../models/ping_data.dart';
import '../providers/app_state_provider.dart';

/// Map widget with TX/RX markers
/// Uses flutter_map with OpenStreetMap tiles
class MapWidget extends StatefulWidget {
  const MapWidget({super.key});

  @override
  State<MapWidget> createState() => _MapWidgetState();
}

class _MapWidgetState extends State<MapWidget> {
  final MapController _mapController = MapController();
  
  // Default center (Ottawa)
  static const LatLng _defaultCenter = LatLng(45.4215, -75.6972);
  static const double _defaultZoom = 12.0;

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    
    // Determine map center
    LatLng center = _defaultCenter;
    if (appState.currentPosition != null) {
      center = LatLng(
        appState.currentPosition!.latitude,
        appState.currentPosition!.longitude,
      );
    }

    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: center,
        initialZoom: _defaultZoom,
        minZoom: 3,
        maxZoom: 18,
      ),
      children: [
        // Tile layer (OpenStreetMap)
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.meshmapper.app',
          maxZoom: 19,
        ),
        
        // TX markers (green)
        MarkerLayer(
          markers: _buildTxMarkers(appState.txPings),
        ),
        
        // RX markers (colored by repeater)
        MarkerLayer(
          markers: _buildRxMarkers(appState.rxPings),
        ),
        
        // Current position marker
        if (appState.currentPosition != null)
          MarkerLayer(
            markers: [
              Marker(
                point: LatLng(
                  appState.currentPosition!.latitude,
                  appState.currentPosition!.longitude,
                ),
                width: 40,
                height: 40,
                child: _buildCurrentPositionMarker(),
              ),
            ],
          ),
        
        // Attribution
        const RichAttributionWidget(
          attributions: [
            TextSourceAttribution('OpenStreetMap contributors'),
          ],
        ),
      ],
    );
  }

  List<Marker> _buildTxMarkers(List<TxPing> pings) {
    return pings.map((ping) {
      return Marker(
        point: LatLng(ping.latitude, ping.longitude),
        width: 24,
        height: 24,
        child: Tooltip(
          message: 'TX: ${ping.power}dBm',
          child: Container(
            decoration: BoxDecoration(
              color: Colors.green,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: const Icon(
              Icons.arrow_upward,
              color: Colors.white,
              size: 14,
            ),
          ),
        ),
      );
    }).toList();
  }

  List<Marker> _buildRxMarkers(List<RxPing> pings) {
    return pings.map((ping) {
      final color = Color(RepeaterInfo.colorFromId(ping.repeaterId));
      
      return Marker(
        point: LatLng(ping.latitude, ping.longitude),
        width: 20,
        height: 20,
        child: Tooltip(
          message: 'RX from ${ping.repeaterId}\nSNR: ${ping.snr.toStringAsFixed(1)}',
          child: Container(
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 1.5),
            ),
            child: const Icon(
              Icons.arrow_downward,
              color: Colors.white,
              size: 12,
            ),
          ),
        ),
      );
    }).toList();
  }

  Widget _buildCurrentPositionMarker() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.blue.withValues(alpha: 0.3),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.blue, width: 3),
      ),
      child: Center(
        child: Container(
          width: 12,
          height: 12,
          decoration: const BoxDecoration(
            color: Colors.blue,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }

  /// Center map on current position
  void centerOnPosition() {
    final appState = context.read<AppStateProvider>();
    if (appState.currentPosition != null) {
      _mapController.move(
        LatLng(
          appState.currentPosition!.latitude,
          appState.currentPosition!.longitude,
        ),
        _mapController.camera.zoom,
      );
    }
  }
}
