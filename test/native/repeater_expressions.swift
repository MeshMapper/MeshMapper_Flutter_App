import Foundation
import MapLibre

// Run against the pinned iOS SDK, without requiring an API key or a full app.
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let expressions = try JSONSerialization.jsonObject(with: data) as! [String: Any]
for name in expressions.keys.sorted() {
    let source = MLNShapeSource(identifier: "source", features: [], options: nil)
    let layer = MLNSymbolStyleLayer(identifier: name, source: source)
    print("Checking \(name)")
    fflush(stdout)
    let expression = NSExpression(mglJSONObject: expressions[name]!)
    // Exercise Foundation's predicate conversion as well as native parsing.
    // Step expressions are only evaluated by the native renderer, so dots
    // are checked by the layer setter below and the Dart reference tests.
    // Every combination of zero, one and two includes every tie/presence shape.
    let statuses = ["active", "new", "dead", "dup", "backbone"]
    for sample in 0..<(name == "badge" ? 243 : 0) {
        var value = sample
        var counts: [Int] = []
        var properties: [String: Int] = [:]
        for status in statuses {
            counts.append(value % 3)
            properties["rc_" + status] = value % 3
            value /= 3
        }
        let winner = counts.firstIndex(of: counts.max()!)!
        let expected = "badge_" + statuses[winner]
        let actual = expression.expressionValue(with: properties, context: nil) as? String
        precondition(actual == expected, "\(name): \(counts) gave \(String(describing: actual)), expected \(expected)")
    }
    layer.iconImageName = expression
    precondition(layer.iconImageName != nil)
    print("PASS \(name)")
}
