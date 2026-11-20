import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/reconnect_flap_guard.dart';

/// A radio that reconnects and then drops again within seconds must not loop
/// forever. One log showed about 140 reconnect cycles with no alert, because
/// every drop started a fresh 30 s budget and every success cleared it.

void main() {
  final t0 = DateTime(2026, 11, 8, 12);
  DateTime at(int s) => t0.add(Duration(seconds: s));

  test('three quick drops after reconnects in a row give up', () {
    final guard = ReconnectFlapGuard();
    // The first drop follows a manual connect, not a reconnect.
    expect(guard.onDrop(at(0)), isFalse);
    guard.onReconnectSuccess(at(5));
    expect(guard.onDrop(at(10)), isFalse);
    guard.onReconnectSuccess(at(15));
    expect(guard.onDrop(at(20)), isFalse);
    guard.onReconnectSuccess(at(25));
    expect(guard.onDrop(at(30)), isTrue);
  });

  test('a connection that stays up past the window resets the count', () {
    final guard = ReconnectFlapGuard();
    guard.onReconnectSuccess(at(0));
    expect(guard.onDrop(at(5)), isFalse);
    guard.onReconnectSuccess(at(10));
    expect(guard.onDrop(at(15)), isFalse);
    guard.onReconnectSuccess(at(20));
    // Up for 31 s: a healthy link that later dropped.
    expect(guard.onDrop(at(51)), isFalse);
    expect(guard.flaps, 0);
    guard.onReconnectSuccess(at(55));
    expect(guard.onDrop(at(60)), isFalse);
    guard.onReconnectSuccess(at(65));
    expect(guard.onDrop(at(70)), isFalse);
  });

  test('the window boundary counts as quick', () {
    final guard = ReconnectFlapGuard();
    for (var i = 0; i < 2; i++) {
      guard.onReconnectSuccess(at(i * 100));
      expect(guard.onDrop(at(i * 100 + 30)), isFalse);
    }
    guard.onReconnectSuccess(at(300));
    expect(guard.onDrop(at(330)), isTrue);
  });

  test('a drop with no reconnect before it does not count', () {
    final guard = ReconnectFlapGuard();
    guard.onReconnectSuccess(at(0));
    expect(guard.onDrop(at(5)), isFalse);
    guard.onReconnectSuccess(at(10));
    expect(guard.onDrop(at(15)), isFalse);
    // A manual connect after the abandon: the next drop starts over.
    guard.reset();
    expect(guard.onDrop(at(20)), isFalse);
    expect(guard.flaps, 0);
  });
}
