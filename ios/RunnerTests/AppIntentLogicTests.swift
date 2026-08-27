import XCTest

@testable import Runner

final class AppIntentLogicTests: XCTestCase {
  func testConnectLastCompanionCommandUsesDedicatedWireKind() {
    let command = SiriCommand(kind: .connectLastCompanion)
    let payload = command.dictionary(expiresAt: Date())

    XCTAssertEqual(payload["source"] as? String, "siri")
    XCTAssertEqual(payload["kind"] as? String, "connectLastCompanion")
    XCTAssertNil(payload["mode"] as? String)
    XCTAssertNil(payload["sessionId"] as? String)
  }

  func testCommandCarriesTheSameDeadlineTheIntentWaitsOn() {
    // Dart must be able to stop for the same reason, and at the same instant,
    // that the intent stops waiting — otherwise a slow start reaches the radio
    // after the person has already been told it failed.
    let command = SiriCommand(kind: .startSession, mode: "active")
    let expiresAt = Date().addingTimeInterval(command.responseTimeout)
    let payload = command.dictionary(expiresAt: expiresAt)

    XCTAssertEqual(command.responseTimeout, 10)
    XCTAssertEqual(
      payload["expiresAtMs"] as? Int64,
      Int64(expiresAt.timeIntervalSince1970 * 1_000)
    )
  }

  func testOnlyCancellableKindsClaimCancellation() {
    // Dart holds the same deadline for these two and checks it before every RF
    // send, so "cancelled" is literally true for them.
    for kind in [SiriCommand.Kind.startSession, .manualPing] {
      XCTAssertEqual(
        SiriBridgeError.timedOut(kind).errorDescription,
        "MeshMapper took too long, so the request was cancelled."
      )
    }

    // Connect cannot be called back once a transport is dialling, and Stop is
    // deliberately exempt from the deadline and may still be tearing down.
    // Neither may claim cancellation.
    let connect =
      SiriBridgeError.timedOut(.connectLastCompanion).errorDescription ?? ""
    XCTAssertEqual(
      connect,
      "MeshMapper didn't answer in time, and may still be connecting. Check the app in a moment."
    )

    let stop = SiriBridgeError.timedOut(.stopSession).errorDescription ?? ""
    XCTAssertEqual(
      stop,
      "MeshMapper didn't answer in time, and may still be stopping. Check the app in a moment."
    )

    XCTAssertFalse(connect.contains("cancelled"))
    XCTAssertFalse(stop.contains("cancelled"))
  }

  func testConnectAllowsLongerThanTheOtherMutations() {
    XCTAssertEqual(SiriCommand(kind: .connectLastCompanion).responseTimeout, 30)
    XCTAssertEqual(SiriCommand(kind: .stopSession).responseTimeout, 10)
    XCTAssertEqual(SiriCommand(kind: .manualPing).responseTimeout, 10)
  }

  func testDecodesVersionOneSnapshotWithoutUserCoordinates() throws {
    let json = """
      {
        "version": 1,
        "updatedAtMs": 1787529600000,
        "connection": {
          "isConnected": true,
          "deviceName": "MeshCore",
          "batteryPercent": 83,
          "gpsStatus": "fresh"
        },
        "session": {
          "id": "session-1",
          "startedAtMs": 1787529000000,
          "active": true,
          "starting": false,
          "mode": "passive",
          "phase": "listening",
          "phaseTitle": "Listening",
          "phaseDetail": null,
          "phaseEndsAtMs": null,
          "zoneCode": "US-CA",
          "txCount": 0,
          "rxCount": 1,
          "discoveryCount": 0,
          "traceCount": 0,
          "queueSize": 0,
          "uniqueRepeatersHeard": 1
        },
        "controls": {
          "availableStartModes": ["active", "passive", "hybrid"],
          "canStart": false,
          "startBlockedReason": "A session is already running.",
          "canStop": true,
          "canManualPing": false,
          "manualPingBlockedReason": "Manual ping is unavailable in passive mode.",
          "manualCooldownEndsAtMs": null
        },
        "recentHeard": [{
          "entityId": "repeater-1",
          "displayHexId": "A1B2C3D4",
          "name": "Ridge",
          "observedAtMs": 1787529590000,
          "kind": "passiveRx",
          "direct": true,
          "hopCount": 0,
          "snr": 7.5,
          "rssi": -91,
          "distanceM": 1200.0,
          "repeaterLat": 37.1,
          "repeaterLon": -122.1,
          "resolved": true
        }],
        "repeaters": [{
          "id": "repeater-1",
          "name": "Ridge",
          "hexId": "A1B2C3D4",
          "zoneCode": "US-CA",
          "isActive": true,
          "isNew": false,
          "serverLastHeardMs": 1787529590000,
          "latitude": 37.1,
          "longitude": -122.1
        }]
      }
      """

    let snapshot = try JSONDecoder().decode(
      MeshMapperSiriSnapshot.self,
      from: XCTUnwrap(json.data(using: .utf8))
    )

    XCTAssertEqual(snapshot.version, MeshMapperSiriSnapshotStore.supportedVersion)
    XCTAssertEqual(snapshot.session.id, "session-1")
    XCTAssertEqual(
      snapshot.session.startedAt,
      Date(timeIntervalSince1970: 1_787_529_000)
    )
    XCTAssertEqual(snapshot.recentHeard.first?.entityId, "repeater-1")
    XCTAssertEqual(snapshot.recentHeard.first?.repeaterLat, 37.1)
    XCTAssertEqual(
      snapshot.recentHeard.first?.stableEntityIdentifier,
      "repeater-1|1787529590000|passiveRx|direct|0"
    )
    XCTAssertFalse(json.contains("userLat"))
    XCTAssertFalse(json.contains("userLon"))
  }

  func testSnapshotFromAnOlderBuildStillDecodesWithoutASessionStart() throws {
    // startedAtMs is additive within version 1, so an extension updated ahead
    // of the app must keep reading the file the old app left behind.
    let json = """
      {
        "version": 1,
        "updatedAtMs": 1787529600000,
        "connection": {
          "isConnected": false,
          "deviceName": null,
          "batteryPercent": null,
          "gpsStatus": "unavailable"
        },
        "session": {
          "id": null,
          "active": false,
          "starting": false,
          "mode": "idle",
          "phase": "idle",
          "phaseTitle": "Idle",
          "phaseDetail": null,
          "phaseEndsAtMs": null,
          "zoneCode": null,
          "txCount": 0,
          "rxCount": 0,
          "discoveryCount": 0,
          "traceCount": 0,
          "queueSize": 0,
          "uniqueRepeatersHeard": 0
        },
        "controls": {
          "availableStartModes": [],
          "canStart": false,
          "startBlockedReason": "Connect first.",
          "canStop": false,
          "canManualPing": false,
          "manualPingBlockedReason": "Connect first.",
          "manualCooldownEndsAtMs": null
        },
        "recentHeard": [],
        "repeaters": []
      }
      """

    let snapshot = try JSONDecoder().decode(
      MeshMapperSiriSnapshot.self,
      from: XCTUnwrap(json.data(using: .utf8))
    )

    XCTAssertNil(snapshot.session.startedAtMs)
    XCTAssertNil(snapshot.session.startedAt)
  }

  func testRejectsUnsupportedSnapshotVersionBeforeWriting() {
    let snapshot = MeshMapperSiriSnapshot(
      version: 2,
      updatedAtMs: 0,
      connection: MeshMapperSiriConnection(
        isConnected: false,
        deviceName: nil,
        batteryPercent: nil,
        gpsStatus: "unavailable"
      ),
      session: MeshMapperSiriSession(
        id: nil,
        startedAtMs: nil,
        active: false,
        starting: false,
        mode: "none",
        phase: "idle",
        phaseTitle: "Idle",
        phaseDetail: nil,
        phaseEndsAtMs: nil,
        zoneCode: nil,
        txCount: 0,
        rxCount: 0,
        discoveryCount: 0,
        traceCount: 0,
        queueSize: 0,
        uniqueRepeatersHeard: 0
      ),
      controls: MeshMapperSiriControls(
        availableStartModes: ["active", "passive", "hybrid"],
        canStart: false,
        startBlockedReason: "Connect first.",
        canStop: false,
        canManualPing: false,
        manualPingBlockedReason: "Connect first.",
        manualCooldownEndsAtMs: nil
      ),
      recentHeard: [],
      repeaters: []
    )

    XCTAssertThrowsError(try MeshMapperSiriSnapshotStore().write(snapshot)) { error in
      guard case MeshMapperSiriSnapshotStoreError.unsupportedVersion(2) = error else {
        return XCTFail("Expected unsupportedVersion(2), got \(error)")
      }
    }
  }
}
