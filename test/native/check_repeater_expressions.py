"""Exercise production cluster expressions in the pinned MapLibre iOS SDK.

Usage: python3 test/native/check_repeater_expressions.py FRAMEWORK_DIR DEVICE
FRAMEWORK_DIR contains the simulator MapLibre.framework; DEVICE is a booted
simulator UUID or 'booted'. Requires Flutter and Xcode.
"""
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
framework = pathlib.Path(sys.argv[1]).resolve()
device = sys.argv[2]
sdk = subprocess.check_output(
    ['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True
).strip()
with tempfile.TemporaryDirectory(prefix='repeater-expressions-') as tmp:
    fixture = pathlib.Path(tmp) / 'expressions.json'
    executable = pathlib.Path(tmp) / 'check'
    subprocess.run([
        'flutter', 'test', 'test/native/export_repeater_expressions_test.dart',
        f'--dart-define=REPEATER_EXPRESSIONS_OUTPUT={fixture}',
    ], cwd=root, check=True)
    subprocess.run([
        'xcrun', 'swiftc', '-sdk', sdk, '-target', 'arm64-apple-ios16.0-simulator',
        '-F', str(framework), '-framework', 'MapLibre',
        '-Xlinker', '-rpath', '-Xlinker', str(framework),
        str(root / 'test/native/repeater_expressions.swift'), '-o', str(executable),
    ], check=True)
    subprocess.run([
        'xcrun', 'simctl', 'spawn', device, str(executable), str(fixture),
    ], check=True)
