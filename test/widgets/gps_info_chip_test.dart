import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mesh_mapper/widgets/gps_info_chip.dart';

/// The map's GPS chip is a pure function of the readings it is given, so the
/// map widget can rebuild it per fix through a Selector without rebuilding
/// the map. It shows accuracy, the distance since the last ping, and the
/// fix's altitude when the phone knows it.

Position _pos({double altitude = 0.0, double altitudeAccuracy = 0.0}) =>
    Position(
      latitude: 45.0,
      longitude: -75.0,
      timestamp: DateTime.now(),
      accuracy: 5.0,
      altitude: altitude,
      altitudeAccuracy: altitudeAccuracy,
      heading: 0.0,
      headingAccuracy: 1.0,
      speed: 0.0,
      speedAccuracy: 0.0,
    );

Widget _host(Widget chip) => MaterialApp(home: Scaffold(body: chip));

void main() {
  testWidgets('shows accuracy, distance and a known altitude', (tester) async {
    await tester.pumpWidget(_host(GpsInfoChip(
      readings: GpsChipReadings.from(
        position: _pos(altitude: 1000, altitudeAccuracy: 1),
        distanceFromLastPing: 42,
        isImperial: false,
      ),
    )));
    expect(find.text('5m'), findsOneWidget);
    expect(find.text('42m'), findsOneWidget);
    expect(find.text('1000m'), findsOneWidget);
  });

  testWidgets('hides the altitude when the fix has none', (tester) async {
    await tester.pumpWidget(_host(GpsInfoChip(
      readings: GpsChipReadings.from(
        position: _pos(),
        distanceFromLastPing: null,
        isImperial: false,
      ),
    )));
    expect(find.text('5m'), findsOneWidget);
    expect(find.byIcon(Icons.height), findsNothing);
  });

  testWidgets('says No GPS without a fix', (tester) async {
    await tester.pumpWidget(_host(GpsInfoChip(
      readings: GpsChipReadings.from(
        position: null,
        distanceFromLastPing: null,
        isImperial: false,
      ),
    )));
    expect(find.text('No GPS'), findsOneWidget);
  });

  test('readings compare by value so a Selector only rebuilds on a change', () {
    final a = GpsChipReadings.from(
      position: _pos(altitude: 1000, altitudeAccuracy: 1),
      distanceFromLastPing: 42,
      isImperial: false,
    );
    final b = GpsChipReadings.from(
      position: _pos(altitude: 1000, altitudeAccuracy: 1),
      distanceFromLastPing: 42,
      isImperial: false,
    );
    final c = GpsChipReadings.from(
      position: _pos(altitude: 2000, altitudeAccuracy: 1),
      distanceFromLastPing: 42,
      isImperial: false,
    );
    expect(a, b);
    expect(a, isNot(c));
  });
}
