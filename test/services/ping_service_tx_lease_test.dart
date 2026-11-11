import 'dart:convert';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mesh_mapper/models/connection_state.dart';
import 'package:mesh_mapper/models/ping_data.dart';
import 'package:mesh_mapper/services/api_queue_service.dart';
import 'package:mesh_mapper/services/countdown_timer_service.dart';
import 'package:mesh_mapper/services/fix_altitude.dart';
import 'package:mesh_mapper/services/gps_service.dart';
import 'package:mesh_mapper/services/meshcore/crypto_service.dart';
import 'package:mesh_mapper/services/meshcore/packet_metadata.dart';
import 'package:mesh_mapper/services/meshcore/protocol_constants.dart';
import 'package:mesh_mapper/services/meshcore/tx_tracker.dart';
import 'package:mesh_mapper/services/ping_service.dart';
import 'package:mesh_mapper/services/wakelock_service.dart';

import 'meshcore/scope_test_support.dart';

/// A TX that queues behind a scope lease must not spend its echo window
/// waiting. The real PingService, connection, lease and TxTracker run
/// together: the lease holds the write gate for 3.5 s, and an echo that
/// arrives 2 s after the TX actually went out must still count.

class _FakeGps implements GpsService {
  @override
  FixAltitude fixAltitudeOf(Position position) => FixAltitude.known(
      meters: 84.0, reference: AltitudeReference.msl, accuracy: 6.0);

  final Position position = Position(
    latitude: 45.0,
    longitude: -75.0,
    timestamp: DateTime(2026),
    accuracy: 5.0,
    altitude: 0.0,
    altitudeAccuracy: 1.0,
    heading: 0.0,
    headingAccuracy: 1.0,
    speed: 0.0,
    speedAccuracy: 1.0,
  );

  @override
  GpsStatus get status => GpsStatus.locked;

  @override
  Position? get lastPosition => position;

  @override
  bool isAccuracyAcceptableForPing(Position position) => true;

  @override
  bool get isAirborne => false;

  @override
  void markPingPosition(Position position) {}

  @override
  void markActivityPosition(Position position) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('GpsService.${invocation.memberName}');
}

class _FakeApiQueue implements ApiQueueService {
  final List<String> txHeard = [];
  final List<(double?, String?, double?)> txAltitude = [];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #enqueueTx) {
      txHeard.add(invocation.namedArguments[#heardRepeats] as String);
      txAltitude.add((
        invocation.namedArguments[#altitude] as double?,
        invocation.namedArguments[#altitudeRef] as String?,
        invocation.namedArguments[#altitudeAccuracy] as double?,
      ));
      return Future<void>.value();
    }
    if (invocation.memberName.toString().contains('enqueue')) {
      return Future<void>.value();
    }
    throw UnimplementedError('ApiQueueService.${invocation.memberName}');
  }
}

class _FakeWakelock implements WakelockService {
  @override
  bool get isEnabled => false;

  @override
  Future<void> enable() async {}

  @override
  Future<void> disable() async {}

  @override
  Future<void> dispose() async {}
}

/// A one-hop flood echo of [message] on the channel with [key], heard via
/// repeater 0x4E.
PacketMetadata _echo(String message, Uint8List key) {
  final plain = Uint8List.fromList(
      [0, 0, 0, 0, 0, ...utf8.encode(message)]); // timestamp, flags, text
  final encrypted = CryptoService.encryptChannelMessage(plain, key);
  const header = (PayloadType.grpTxt << PacketHeader.typeShift) |
      RouteType.flood;
  return PacketMetadata.fromLogRxData({
    'raw': Uint8List.fromList([
      header,
      0x01, // one 1-byte hop
      0x4E,
      CryptoService.computeChannelHash(key),
      0, 0, // MAC
      ...encrypted,
    ]),
    'lastSnr': 5.0,
    'lastRssi': -80,
  });
}

void main() {
  test('a TX parked behind a lease starts its echo window when it goes out',
      () {
    onScopeClock(PollingScopeRadio.new, (async, radio, conn) {
      conn.connect((_) async => null);
      async.elapse(const Duration(seconds: 5));
      expect(conn.wardrivingChannelKey, isNotNull);

      final tracker = TxTracker();
      final queue = _FakeApiQueue();
      final ping = PingService(
        gpsService: _FakeGps(),
        connection: conn,
        apiQueue: queue,
        wakelockService: _FakeWakelock(),
        cooldownTimer: CooldownTimer(),
        manualPingCooldownTimer: ManualPingCooldownTimer(),
        rxWindowTimer: RxWindowTimer(),
        discoveryWindowTimer: DiscoveryWindowTimer(),
        deviceId: 'TEST',
        txTracker: tracker,
      )..getSessionId = () => 'PAR-20260611-0013';
      TxPing? recorded;
      ping.onTxPing = (txPing) => recorded = txPing;

      final lease = grant(async, conn)!;
      var sent = false;
      ping.sendTxPing(manual: true).then((ok) => sent = ok);
      async.elapse(const Duration(milliseconds: 3500));
      expect(radio.count(CommandCodes.sendChannelTxtMsg), 0,
          reason: 'the TX is still parked behind the lease');

      lease.release();
      async.flushMicrotasks();
      expect(radio.count(CommandCodes.sendChannelTxtMsg), 1);
      final wentOut = clock.now();
      radio.emit([ResponseCodes.ok]);
      async.flushMicrotasks();
      expect(sent, isTrue);
      expect(recorded?.timestamp, wentOut,
          reason: 'the ping is recorded at the moment it went out');

      async.elapse(const Duration(seconds: 2));
      expect(tracker.isListening, isTrue,
          reason: 'the echo window runs from the send, not from the wait');
      TxEchoResult? result;
      tracker
          .handlePacket(_echo(tracker.sentPayload!, conn.wardrivingChannelKey!))
          .then((r) => result = r);
      async.flushMicrotasks();
      expect(result, TxEchoResult.directEcho);
      expect(recorded!.heardRepeaters.single.repeaterId, '4E');

      async.elapse(const Duration(seconds: 4));
      expect(queue.txHeard, ['4E(5.00)']);
      expect(queue.txAltitude, [(84.0, 'msl', 6.0)],
          reason: 'the labelled altitude rides the TX enqueue');
      ping.dispose();
    });
  });
}
