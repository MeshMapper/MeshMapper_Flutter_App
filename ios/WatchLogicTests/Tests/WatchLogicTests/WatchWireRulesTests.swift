import Foundation
import XCTest

@testable import WatchWire

/// Tests for the wire's timing rules — the decisions that pick what the wearer
/// sees. Everything here was previously reachable only through
/// `WatchSessionClient`, which needs a paired watch to exercise at all.
final class WatchWireRulesTests: XCTestCase {
  private let base = Date(timeIntervalSince1970: 1_770_000_000)

  private func snapshot(updatedAt: Date, sessionId: String = "s1") -> WatchSnapshot {
    WatchSnapshot(
      wireVersion: 2,
      sessionId: sessionId,
      mode: "Passive",
      phase: "active",
      phaseTitle: "Passive active",
      phaseDetail: nil,
      phaseEndsAtMs: nil,
      phaseDurationMs: nil,
      isConnected: true,
      zoneCode: "SEA",
      txCount: 0,
      rxCount: 0,
      discoveryCount: 0,
      traceCount: 0,
      queueSize: 0,
      pingColor: nil,
      geo: WatchGeo(
        you: nil,
        pings: [],
        repeaters: [],
        heard: [],
        linkedRepeaterIds: []
      ),
      controls: WatchControls(
        canStartStop: true,
        canManualPing: false,
        isSessionActive: true,
        manualPingApplicable: false,
        manualCooldownEndsAtMs: nil,
        blockedReason: nil
      ),
      cue: nil,
      updatedAtMs: updatedAt.timeIntervalSince1970 * 1000
    )
  }

  private func cue(issuedAt: Date?) -> WatchHapticCue {
    WatchHapticCue(
      id: "cue-1",
      kind: "failure",
      issuedAtMs: issuedAt.map { $0.timeIntervalSince1970 * 1000 },
      message: "Could not start"
    )
  }

  // MARK: - Ordering

  func testFirstSnapshotIsAlwaysAccepted() {
    XCTAssertTrue(
      WatchWireRules.supersedes(
        snapshot(updatedAt: base), current: nil, isStale: false
      )
    )
  }

  func testNewerSnapshotSupersedes() {
    XCTAssertTrue(
      WatchWireRules.supersedes(
        snapshot(updatedAt: base.addingTimeInterval(1)),
        current: snapshot(updatedAt: base),
        isStale: false
      )
    )
  }

  /// The defect this rule exists for. The phone sends P2 down both paths, the
  /// watch applies P2 from the live message, the wrist drops and rises before
  /// context P2 arrives, and `resume` ingests a retained context still holding
  /// P1. Last-writer-wins walked the wearer backwards onto state too young to
  /// look stale, so nothing asked for anything better.
  func testASlowRetainedContextCannotOverwriteANewerLiveOne() {
    let p1 = snapshot(updatedAt: base)
    let p2 = snapshot(updatedAt: base.addingTimeInterval(5))

    XCTAssertFalse(
      WatchWireRules.supersedes(p1, current: p2, isStale: false),
      "an out-of-order application context must not replace a newer live payload"
    )
  }

  /// A forced refresh restamps `updatedAt`, so it is strictly newer and can
  /// never be mistaken for a replay of itself. Equal stamps are still accepted:
  /// two payloads built in the same millisecond are interchangeable.
  func testIdenticalTimestampsAreAccepted() {
    XCTAssertTrue(
      WatchWireRules.supersedes(
        snapshot(updatedAt: base),
        current: snapshot(updatedAt: base),
        isStale: false
      )
    )
  }

  /// The bound that keeps a backwards phone clock from being permanent. Once
  /// the held snapshot is stale, anything is better than what is on screen.
  func testAStaleSurfaceAcceptsAnythingSoAClockStepCannotStall() {
    let older = snapshot(updatedAt: base)
    let newer = snapshot(updatedAt: base.addingTimeInterval(60))

    XCTAssertFalse(
      WatchWireRules.supersedes(older, current: newer, isStale: false)
    )
    XCTAssertTrue(
      WatchWireRules.supersedes(older, current: newer, isStale: true),
      "refusal must lift at the stale boundary, or the watch never recovers"
    )
  }

  // MARK: - Cue presentation

  func testAFreshCueIsFelt() {
    XCTAssertEqual(
      WatchWireRules.presentation(
        for: cue(issuedAt: base), at: base.addingTimeInterval(5),
        clockOffset: nil
      ),
      .feel
    )
  }

  /// The wrist-down case. Too old to buzz for, but still the only account of
  /// the failure the wearer will ever get.
  func testACueTooOldToFeelIsStillRead() {
    XCTAssertEqual(
      WatchWireRules.presentation(
        for: cue(issuedAt: base), at: base.addingTimeInterval(45),
        clockOffset: nil
      ),
      .read
    )
  }

  func testACueIsDroppedAtTheStaleBoundary() {
    XCTAssertEqual(
      WatchWireRules.presentation(
        for: cue(issuedAt: base),
        at: base.addingTimeInterval(WatchWireRules.staleAfter + 1),
        clockOffset: nil
      ),
      .drop,
      "past the boundary the whole surface reads as old; a cue must not claim to be current"
    )
  }

  /// The phone stops attaching a cue at exactly this boundary
  /// (`WatchWire.cueReadableFor`). If the two ever drift apart, one side is
  /// sending bytes the other discards, or dropping a failure the other expects
  /// to show.
  func testTheReadWindowEndsWhereTheSurfaceGoesStale() {
    XCTAssertEqual(
      WatchWireRules.presentation(
        for: cue(issuedAt: base),
        at: base.addingTimeInterval(WatchWireRules.staleAfter - 1),
        clockOffset: nil
      ),
      .read
    )
  }

  func testAnUndatedCueIsDroppedRatherThanReplayed() {
    XCTAssertEqual(
      WatchWireRules.presentation(for: cue(issuedAt: nil), at: base, clockOffset: nil),
      .drop
    )
  }

  /// A few seconds of skew must not suppress a real failure that has just
  /// crossed the radio, but a wildly future-dated one is not credible.
  func testSkewIsToleratedButAFutureCueIsNot() {
    XCTAssertEqual(
      WatchWireRules.presentation(
        for: cue(issuedAt: base.addingTimeInterval(2)), at: base, clockOffset: nil
      ),
      .feel
    )
    XCTAssertEqual(
      WatchWireRules.presentation(
        for: cue(issuedAt: base.addingTimeInterval(120)), at: base, clockOffset: nil
      ),
      .drop
    )
  }

  /// The offset converts a phone stamp into watch time. Without it applied, a
  /// phone running a minute ahead would look like a cue from the future and be
  /// dropped — the failure the offset exists to prevent.
  func testTheClockOffsetIsAppliedBeforeAging() {
    let phoneAheadBy: TimeInterval = 60
    let issued = base.addingTimeInterval(phoneAheadBy)

    XCTAssertEqual(
      WatchWireRules.presentation(for: cue(issuedAt: issued), at: base, clockOffset: nil),
      .drop
    )
    XCTAssertEqual(
      WatchWireRules.presentation(
        for: cue(issuedAt: issued), at: base, clockOffset: phoneAheadBy
      ),
      .feel
    )
  }

  // MARK: - Reception age

  func testAgeRunsFromWhenThePhoneBuiltThePayload() {
    // Launch ingests a retained context that can be hours old. Stamping
    // arrival would present long-dead state as fresh for a full 90 seconds.
    //
    // Note the direction of the tolerance: origin is `producedAt` plus
    // `clockTolerance`, not `producedAt`. The slack is spent making a payload
    // look *younger*, so ordinary skew cannot age a genuinely live one early —
    // it is not a symmetric error bar. A snapshot therefore reads up to five
    // seconds fresher than it is, which is the intended trade and the reason
    // the clamp to `arrival` below has to exist.
    let produced = base
    let arrival = base.addingTimeInterval(60)
    let result = WatchWireRules.reception(
      arrival: arrival, producedAt: produced, clockOffset: nil
    )

    XCTAssertEqual(
      result.origin,
      produced.addingTimeInterval(WatchWireRules.clockTolerance)
    )
    XCTAssertEqual(
      result.remaining,
      WatchWireRules.staleAfter - 60 + WatchWireRules.clockTolerance,
      accuracy: 0.001
    )
  }

  func testARetainedContextArrivesAlreadyStale() {
    let result = WatchWireRules.reception(
      arrival: base.addingTimeInterval(3600), producedAt: base, clockOffset: nil
    )

    XCTAssertLessThanOrEqual(result.remaining, 0)
  }

  /// A phone clock running fast must not be able to date a payload into the
  /// future and extend its life beyond the boundary.
  func testAFastPhoneClockCannotExtendASnapshotsLife() {
    let arrival = base
    let result = WatchWireRules.reception(
      arrival: arrival,
      producedAt: base.addingTimeInterval(600),
      clockOffset: nil
    )

    XCTAssertEqual(result.origin, arrival, "origin is clamped to arrival")
    XCTAssertEqual(result.remaining, WatchWireRules.staleAfter, accuracy: 0.001)
  }

  func testAnUndatedPayloadAgesFromArrival() {
    let result = WatchWireRules.reception(
      arrival: base, producedAt: nil, clockOffset: nil
    )

    XCTAssertEqual(result.origin, base)
    XCTAssertEqual(result.remaining, WatchWireRules.staleAfter, accuracy: 0.001)
  }
}
