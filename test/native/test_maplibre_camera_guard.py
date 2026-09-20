"""Run the production Swift camera gate without requiring a phone or MapLibre.

The method prefix is compiled verbatim; only the native map and downstream
camera operation are replaced. This tests scheduling and result completion,
not the renderer. Run with python3 -m unittest discover -s test/native.
"""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
CONTROLLER = ROOT / (
    "third_party/maplibre_gl/ios/maplibre_gl/Sources/maplibre_gl/"
    "MapLibreMapController.swift"
)


class CameraGuardTest(unittest.TestCase):
    def test_camera_calls_finish_without_touching_an_unusable_viewport(self):
        source = Path(os.environ.get("MAPLIBRE_SWIFT_CONTROLLER", CONTROLLER)).read_text()
        start = source.index("    func onMethodCall(")
        end = source.index("        switch methodCall.method", start)
        gate = source[start:end]
        harness = r'''
import Foundation
import CoreGraphics

typealias FlutterResult = (Any?) -> Void
struct FlutterMethodCall { let method: String }
final class MapView {
    var bounds = CGRect.zero
    var frame: CGRect { bounds }
}
final class Controller {
    var mapView = MapView()
    var operations = 0
__GATE__
        operations += 1
        result(true)
    }
}

var failures = [String]()
func check(_ ok: Bool, _ message: String) {
    if !ok { failures.append(message) }
}
func pump(_ duration: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(duration))
}

for method in ["camera#move", "camera#animate", "camera#ease"] {
    for (width, height) in [(0.0, 0.0), (0.0, 100.0), (100.0, 0.5)] {
        let controller = Controller()
        controller.mapView.bounds.size = CGSize(width: width, height: height)
        var results = [Bool?]()
        controller.onMethodCall(methodCall: FlutterMethodCall(method: method)) {
            results.append($0 as? Bool)
        }
        pump(0.4)
        check(controller.operations == 0, "\(method) touched \(width)x\(height) viewport")
        check(results.count == 1 && results.first! == false,
              "\(method) must complete once with false for \(width)x\(height)")
    }
}

do {
    let controller = Controller()
    var results = [Bool?]()
    controller.onMethodCall(methodCall: FlutterMethodCall(method: "camera#animate")) {
        results.append($0 as? Bool)
    }
    check(results.isEmpty, "cold layout must get a chance to recover")
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) {
        controller.mapView.bounds.size = CGSize(width: 320, height: 480)
    }
    pump(0.4)
    check(controller.operations == 1, "recovered layout must execute exactly once")
    check(results.count == 1 && results.first! == true, "recovered call must complete")
}

do {
    var controller: Controller? = Controller()
    weak var released = controller
    var results = [Bool?]()
    controller!.onMethodCall(methodCall: FlutterMethodCall(method: "camera#move")) {
        results.append($0 as? Bool)
    }
    controller = nil
    pump(0.4)
    check(released == nil, "retry must not retain the controller")
    check(results.count == 1 && results.first! == false, "disposed call must complete once")
}

for method in ["camera#move", "map#waitForMap"] {
    let controller = Controller()
    if method.hasPrefix("camera#") {
        controller.mapView.bounds.size = CGSize(width: 1, height: 1)
    }
    var results = [Bool?]()
    controller.onMethodCall(methodCall: FlutterMethodCall(method: method)) {
        results.append($0 as? Bool)
    }
    check(controller.operations == 1 && results.count == 1,
          "usable viewport and non-camera methods must execute immediately")
}

if !failures.isEmpty {
    print(failures.joined(separator: "\n"))
    exit(1)
}
print("Camera gate: persistent, partial, sub-pixel, recovery, disposal and immediate paths passed")
'''.replace("__GATE__", gate)
        with tempfile.TemporaryDirectory() as directory:
            swift = Path(directory) / "main.swift"
            executable = Path(directory) / "camera-guard"
            swift.write_text(harness)
            compiled = subprocess.run(["xcrun", "swiftc", "-swift-version", "5", str(swift),
                                       "-o", str(executable)], capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
