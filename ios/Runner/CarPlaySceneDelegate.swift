import CarPlay
import UIKit

extension Notification.Name {
  static let meshMapperSnapshotDidChange = Notification.Name("MeshMapperSnapshotDidChange")
}

// Personal-build custom dashboard. This is deliberately outside the map-only
// presentation supported by the maps entitlement; do not submit as a map UI.
@available(iOS 16.0, *)
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
  private var dashboard: HeardDashboardController?
  private var observer: NSObjectProtocol?
  private var timer: Timer?

  func templateApplicationScene(_ scene: CPTemplateApplicationScene,
    didConnect controller: CPInterfaceController, to window: CPWindow) {
    stopUpdates()
    let dashboard = HeardDashboardController()
    self.dashboard = dashboard
    window.rootViewController = dashboard
    let template = CPMapTemplate()
    template.automaticallyHidesNavigationBar = true
    template.hidesButtonsWithNavigationBar = true
    controller.setRootTemplate(template, animated: false, completion: nil)
    observer = NotificationCenter.default.addObserver(forName: .meshMapperSnapshotDidChange,
      object: nil, queue: .main) { [weak self] _ in self?.refresh() }
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      self?.refresh()
    }
    refresh()
  }

  func templateApplicationScene(_ scene: CPTemplateApplicationScene,
    didDisconnect controller: CPInterfaceController, from window: CPWindow) {
    stopUpdates()
    dashboard = nil
    window.rootViewController = nil
  }

  private func stopUpdates() {
    timer?.invalidate()
    timer = nil
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
  }

  private func refresh() {
    dashboard?.render(try? MeshMapperSiriSnapshotStore.shared.read())
  }
}

private final class HeardDashboardController: UIViewController, UIScrollViewDelegate {
  private let companion = UILabel()
  private let status = UILabel()
  private let fresh = UIStackView()
  private let previous = UIStackView()
  private var columnViews: [(rows: UIStackView, scroll: UIScrollView, footer: UILabel)] = []

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor(red: 0.05, green: 0.07, blue: 0.11, alpha: 1)
    let title = label("MeshMapper", size: 23, weight: .bold)
    for line in [companion, status] {
      line.font = .systemFont(ofSize: 9)
      line.textColor = .lightGray
      line.textAlignment = .right
      line.adjustsFontSizeToFitWidth = true
      line.minimumScaleFactor = 0.75
    }
    let radio = UIStackView(arrangedSubviews: [companion, status])
    radio.axis = .vertical
    radio.spacing = 2
    let header = UIStackView(arrangedSubviews: [title, UIView(), radio])
    header.alignment = .center
    header.spacing = 8
    radio.widthAnchor.constraint(lessThanOrEqualTo: header.widthAnchor, multiplier: 0.48).isActive = true
    let columns = UIStackView(arrangedSubviews: [column("This scan · last 60s", rows: fresh),
      column("Previous scans", rows: previous)])
    columns.axis = .horizontal
    columns.distribution = .fillEqually
    columns.spacing = 16
    let content = UIStackView(arrangedSubviews: [header, columns])
    content.axis = .vertical
    content.spacing = 6
    content.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(content)
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
      content.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
      content.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      content.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
    ])
  }

  private func label(_ text: String, size: CGFloat, weight: UIFont.Weight) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = .white
    return label
  }

  private func column(_ title: String, rows: UIStackView) -> UIView {
    rows.axis = .vertical
    rows.spacing = 3
    let scroll = UIScrollView()
    scroll.delegate = self
    rows.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(rows)
    NSLayoutConstraint.activate([
      rows.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
      rows.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
      rows.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
      rows.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
      rows.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
    ])
    let footer = label("", size: 9, weight: .regular)
    footer.textColor = .lightGray
    footer.heightAnchor.constraint(equalToConstant: 12).isActive = true
    columnViews.append((rows, scroll, footer))
    let stack = UIStackView(arrangedSubviews: [label(title, size: 12, weight: .semibold), scroll, footer])
    stack.axis = .vertical
    stack.spacing = 6
    return stack
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    updateOverflow()
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) { updateOverflow() }

  private func updateOverflow() {
    for column in columnViews {
      let top = column.scroll.bounds.minY + column.scroll.adjustedContentInset.top
      let bottom = column.scroll.bounds.maxY - column.scroll.adjustedContentInset.bottom
      var remaining = 0
      for row in column.rows.arrangedSubviews where row.tag == 1 {
        let frame = row.convert(row.bounds, to: column.scroll)
        let below = frame.maxY > bottom + 0.5
        // Preserve layout and scrolling extent; hiding arranged subviews would
        // collapse them and make the overflow rows impossible to scroll to.
        row.alpha = frame.minY >= top - 0.5 && !below ? 1 : 0
        row.accessibilityElementsHidden = row.alpha == 0
        if below { remaining += 1 }
      }
      column.footer.text = remaining > 0 ? "+\(remaining) more" : ""
    }
  }

  func render(_ snapshot: MeshMapperSiriSnapshot?) {
    loadViewIfNeeded()
    // The next one-second tick catches up after scrolling. Rebuilding the
    // stacks during a gesture can clamp the offset and interrupt the swipe.
    guard !columnViews.contains(where: { $0.scroll.isTracking || $0.scroll.isDragging || $0.scroll.isDecelerating }) else { return }
    defer {
      view.setNeedsLayout()
      view.layoutIfNeeded()
      updateOverflow()
    }
    for stack in [fresh, previous] {
      stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
    }
    guard let snapshot else {
      companion.text = "Companion"
      status.text = "Open MeshMapper on your phone"
      return
    }
    let connection = snapshot.connection
    let stale = Date().timeIntervalSince(snapshot.updatedAt) > 30
    companion.text = connection.deviceName ?? "Companion"
    var parts = [String]()
    parts.append(connection.batteryPercent.map { "Battery \($0)%" } ?? "Battery —")
    parts.append(stale ? "Waiting for phone" : (connection.isConnected ? "Connected" : "Disconnected"))
    status.text = parts.joined(separator: " · ")
    let held = snapshot.session.phase == "deferred" || snapshot.session.phase == "skipped"
    let showHeld = !stale && connection.isConnected && held
    if showHeld {
      fresh.addArrangedSubview(scanStatus(shortStatus(snapshot.session.phase, fallback: snapshot.session.phaseTitle),
        detail: nil,
        color: .systemOrange))
    }
    var seen = Set<String>()
    for item in snapshot.recentHeard.sorted(by: { $0.observedAtMs > $1.observedAtMs }) {
      guard seen.insert(item.entityId ?? item.displayHexId.uppercased()).inserted else { continue }
      let age = max(0, Date().timeIntervalSince(item.observedAt))
      guard age <= 300 else { continue }
      let target = age < 60 ? fresh : previous
      target.addArrangedSubview(row(item, age: age))
    }
    if fresh.arrangedSubviews.isEmpty {
      let title = stale ? "Waiting for phone" :
        (!connection.isConnected ? "Disconnected" : shortStatus(snapshot.session.phase, fallback: snapshot.session.phaseTitle))
      fresh.addArrangedSubview(scanStatus(title,
        detail: nil,
        color: .lightGray))
    }
    if previous.arrangedSubviews.isEmpty { previous.addArrangedSubview(label("No older results", size: 14, weight: .regular)) }
  }

  private func shortStatus(_ phase: String, fallback: String) -> String {
    switch phase {
    case "sending": return "Pinging"
    case "listening", "listening_discovery", "listening_trace": return "Listening"
    case "deferred": return "Deferred"
    case "skipped": return "Skipped"
    case "waiting", "waiting_discovery", "waiting_trace": return "Waiting"
    default: return fallback
    }
  }

  private func scanStatus(_ title: String, detail: String?, color: UIColor) -> UIView {
    let heading = label(title, size: 12, weight: .semibold)
    heading.textColor = color
    let stack = UIStackView(arrangedSubviews: [heading])
    stack.axis = .vertical
    stack.spacing = 2
    if let detail, !detail.isEmpty {
      let explanation = label(detail, size: 10, weight: .regular)
      explanation.textColor = .lightGray
      explanation.numberOfLines = 0
      stack.addArrangedSubview(explanation)
    }
    return stack
  }

  private func row(_ item: MeshMapperSiriObservation, age: TimeInterval) -> UIView {
    let progress = min(1, max(0, (age - 60) / 240))
    let ageColor = UIColor(hue: CGFloat((1 - progress) / 3), saturation: 0.75, brightness: 0.95, alpha: 1)
    let color = signalColor(item.snr)
    let dot = label("●", size: 8, weight: .regular)
    dot.textColor = color
    let name = label(item.name ?? item.displayHexId.uppercased(), size: 11, weight: .medium)
    name.lineBreakMode = .byTruncatingTail
    name.adjustsFontSizeToFitWidth = true
    name.minimumScaleFactor = 0.75
    name.textAlignment = .left
    name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let signal = item.snr.map { String(format: "%+.1f", $0) } ?? "—"
    let ageText = age < 60 ? "\(Int(age))s" : "\(Int(age / 60))m \(Int(age) % 60)s"
    let value = label("\(signal) dB  ·  \(ageText)", size: 9, weight: .regular)
    let telemetry = NSMutableAttributedString(string: "\(signal) dB", attributes: [.foregroundColor: color])
    telemetry.append(NSAttributedString(string: "  ·  \(ageText)", attributes: [.foregroundColor: ageColor]))
    value.attributedText = telemetry
    value.setContentCompressionResistancePriority(.required, for: .horizontal)
    // Keep telemetry below the name so long repeater names get the entire
    // column width rather than competing with the signal and age labels.
    let text = UIStackView(arrangedSubviews: [name, value])
    text.axis = .vertical
    text.alignment = .fill
    text.spacing = 1
    dot.setContentHuggingPriority(.required, for: .horizontal)
    let row = UIStackView(arrangedSubviews: [dot, text])
    row.spacing = 4
    row.alignment = .center
    row.isLayoutMarginsRelativeArrangement = true
    row.layoutMargins = UIEdgeInsets(top: 3, left: 5, bottom: 3, right: 5)
    row.backgroundColor = ageColor.withAlphaComponent(0.08)
    row.layer.cornerRadius = 5
    row.heightAnchor.constraint(equalToConstant: 32).isActive = true
    row.tag = 1 // Only repeater rows count toward the overflow indicator.
    row.accessibilityLabel = "\(name.text ?? "Repeater"), \(signal) decibels, \(Int(age)) seconds ago"
    return row
  }

  private func signalColor(_ snr: Double?) -> UIColor {
    guard let snr, snr.isFinite else { return .systemGray }
    if snr >= 5 { return .systemGreen }
    if snr >= 0 { return .systemYellow }
    if snr >= -5 { return .systemOrange }
    return .systemRed
  }
}
