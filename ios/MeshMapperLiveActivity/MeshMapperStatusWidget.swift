import SwiftUI
import WidgetKit

private enum MeshMapperStatusWidgetConstants {
  static let kind = "MeshMapperStatusWidget"
  static let suggestionWindow: TimeInterval = 5 * 60
}

private struct MeshMapperStatusEntry: TimelineEntry {
  let date: Date
  let snapshot: MeshMapperSiriSnapshot?

  /// A recent heard event makes this card timely. WidgetKit uses this clue,
  /// together with on-device behavior, when it decides whether to promote or
  /// suggest the widget. The app cannot force a suggestion in CarPlay.
  var relevance: TimelineEntryRelevance? {
    guard let latest = snapshot?.recentHeard.map(\.observedAtMs).max() else {
      return nil
    }
    let heardAt = Date(timeIntervalSince1970: Double(latest) / 1000)
    let age = max(0, date.timeIntervalSince(heardAt))
    let remaining = MeshMapperStatusWidgetConstants.suggestionWindow - age
    guard remaining > 0 else { return nil }
    return TimelineEntryRelevance(score: 100, duration: remaining)
  }
}

private struct MeshMapperStatusProvider: TimelineProvider {
  func placeholder(in context: Context) -> MeshMapperStatusEntry {
    MeshMapperStatusEntry(date: Date(), snapshot: nil)
  }

  func getSnapshot(
    in context: Context,
    completion: @escaping (MeshMapperStatusEntry) -> Void
  ) {
    completion(MeshMapperStatusEntry(date: Date(), snapshot: loadSnapshot()))
  }

  func getTimeline(
    in context: Context,
    completion: @escaping (Timeline<MeshMapperStatusEntry>) -> Void
  ) {
    let now = Date()
    completion(Timeline(
      entries: [MeshMapperStatusEntry(date: now, snapshot: loadSnapshot())],
      policy: .after(now.addingTimeInterval(15 * 60))
    ))
  }

  private func loadSnapshot() -> MeshMapperSiriSnapshot? {
    try? MeshMapperSiriSnapshotStore.shared.read()
  }
}

/// The iPhone system-small widget family is also the widget family CarPlay
/// presents on its widgets screen. Keep this card sparse and driver-glanceable.
struct MeshMapperStatusWidget: Widget {
  static let kind = MeshMapperStatusWidgetConstants.kind

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: Self.kind, provider: MeshMapperStatusProvider()) {
      MeshMapperStatusWidgetView(entry: $0)
    }
    .configurationDisplayName("Recently Heard")
    .description("Shows recently heard MeshCore repeaters when the information is timely.")
    .supportedFamilies([.systemSmall])
  }
}

private struct MeshMapperStatusWidgetView: View {
  let entry: MeshMapperStatusEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: "antenna.radiowaves.left.and.right")
          .foregroundStyle(Color.cyan)
        Text("RECENTLY HEARD")
          .font(.caption2.weight(.bold))
          .tracking(0.4)
          .lineLimit(1)
        Spacer(minLength: 0)
      }

      if let snapshot = entry.snapshot {
        let rows = Array(recentObservations(snapshot).prefix(3))
        if rows.isEmpty {
          emptyState(snapshot.connection.isConnected ? "Listening…" : "Disconnected")
        } else {
          VStack(spacing: 7) {
            ForEach(rows, id: \.stableEntityIdentifier) { observation in
              repeaterRow(observation)
            }
          }
        }
      } else {
        emptyState("Open MeshMapper")
      }

      Spacer(minLength: 0)
    }
    .padding(12)
    .meshMapperWidgetBackground()
  }

  private func repeaterRow(_ observation: MeshMapperSiriObservation) -> some View {
    HStack(spacing: 6) {
      Circle()
        .fill(observation.direct ? Color.cyan : Color.purple)
        .frame(width: 6, height: 6)
      Text(observation.name ?? observation.displayHexId.uppercased())
        .font(.caption.monospaced().weight(.semibold))
        .lineLimit(1)
      Spacer(minLength: 3)
      if let snr = observation.snr {
        Text(String(format: "%+.1f", snr))
          .font(.caption.monospacedDigit().weight(.semibold))
          .foregroundStyle(snr >= 0 ? Color.green : Color.orange)
      }
    }
  }

  private func emptyState(_ text: String) -> some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }

  private func recentObservations(
    _ snapshot: MeshMapperSiriSnapshot
  ) -> [MeshMapperSiriObservation] {
    let cutoff = entry.date.addingTimeInterval(
      -MeshMapperStatusWidgetConstants.suggestionWindow
    ).timeIntervalSince1970 * 1000
    return snapshot.recentHeard
      .filter { Double($0.observedAtMs) >= cutoff }
      .sorted { $0.observedAtMs > $1.observedAtMs }
  }
}

private extension View {
  @ViewBuilder
  func meshMapperWidgetBackground() -> some View {
    if #available(iOSApplicationExtension 17.0, *) {
      containerBackground(for: .widget) {
        Color(uiColor: .secondarySystemBackground)
      }
    } else {
      background(Color(uiColor: .secondarySystemBackground))
    }
  }
}
