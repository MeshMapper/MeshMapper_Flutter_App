import SwiftUI

/// Placeholder root view.
///
/// Phase 1's only job is proving the target builds, embeds in Runner, and
/// launches on the watch. Phase 3 replaces this with the map.
struct ContentView: View {
  var body: some View {
    VStack(spacing: 4) {
      Image(systemName: "antenna.radiowaves.left.and.right")
        .font(.title2)
      Text("MeshMapper")
        .font(.headline)
      Text("Waiting for iPhone")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }
}

#Preview {
  ContentView()
}
