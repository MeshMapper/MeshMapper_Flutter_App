import SwiftUI

/// Repeaters that answered the most recent ping, strongest first.
///
/// The payload carries up to `MeshMapperWatchWire.maxHeard` rows, but this view
/// never shrinks type to fit them. It uses standard text styles so the wearer's
/// watch text-size setting is honoured and scrolls for whatever doesn't fit —
/// at default size that lands around 5–7 rows on a 45 mm, and at large
/// accessibility sizes it may be 3. That is the correct outcome, not a bug.
struct NodeListView: View {
  @Environment(WatchSessionClient.self) private var client

  private var nodes: [WatchHeardNode] { client.snapshot?.geo.heard ?? [] }

  var body: some View {
    Group {
      if nodes.isEmpty {
        emptyState
      } else {
        List {
          ForEach(nodes) { node in
            NavigationLink {
              NodeDetailView(node: node)
            } label: {
              NodeRow(node: node)
            }
          }
        }
        .listStyle(.carousel)
      }
    }
    .opacity(client.isStale ? 0.5 : 1.0)
  }

  private var emptyState: some View {
    VStack(spacing: 6) {
      Image(systemName: "antenna.radiowaves.left.and.right.slash")
        .font(.title3)
        .foregroundStyle(.secondary)
      Text("Nothing heard yet")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
  }
}

/// One repeater.
///
/// Two lines: identity and signal on top, context underneath. The SNR dot
/// repeats the colour information as a number so the row still reads under a
/// colour-vision palette or in bright sun.
struct NodeRow: View {
  let node: WatchHeardNode

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      HStack(spacing: 5) {
        if let color = node.snrColor {
          Circle()
            .fill(Color(color))
            .frame(width: 7, height: 7)
        }
        Text(node.name)
          .font(.body)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 4)
        if let snr = node.snr {
          Text(snr, format: .number.precision(.fractionLength(1)))
            .font(.body.monospacedDigit())
        }
      }

      Text(subtitle)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .padding(.vertical, 1)
  }

  private var subtitle: String {
    var parts: [String] = [node.hopLabel]
    if let distance = node.distanceLabel { parts.append(distance) }
    return parts.joined(separator: " · ")
  }
}

struct NodeDetailView: View {
  let node: WatchHeardNode

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 5) {
          if let color = node.snrColor {
            Circle().fill(Color(color)).frame(width: 9, height: 9)
          }
          Text(node.name)
            .font(.headline)
            .lineLimit(2)
        }

        detail("ID", node.id)
        if let snr = node.snr {
          detail("SNR", snr.formatted(.number.precision(.fractionLength(1))) + " dB")
        }
        if let rssi = node.rssi {
          detail("RSSI", "\(rssi) dBm")
        }
        detail("Path", node.hopLabel)
        detail("Seen", node.seenCount == 1 ? "once" : "\(node.seenCount)×")
        if let distance = node.distanceLabel {
          detail("Distance", distance)
        }
        detail("Heard", node.heardAt.formatted(date: .omitted, time: .shortened))
      }
      .padding(.horizontal, 4)
    }
  }

  private func detail(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label)
        .font(.caption2)
        .foregroundStyle(.secondary)
      Spacer(minLength: 6)
      Text(value)
        .font(.caption)
        .multilineTextAlignment(.trailing)
    }
  }
}

extension WatchHeardNode {
  var heardAt: Date { Date(timeIntervalSince1970: atMs / 1000) }

  /// `nil` hops means a direct echo — the distinction the iOS map draws too.
  var hopLabel: String {
    guard let hops else { return "direct" }
    return hops == 1 ? "1 hop" : "\(hops) hops"
  }

  var distanceLabel: String? {
    guard let distanceM else { return nil }
    if distanceM < 1000 {
      return "\(Int(distanceM.rounded())) m"
    }
    return (distanceM / 1000).formatted(.number.precision(.fractionLength(1))) + " km"
  }
}
