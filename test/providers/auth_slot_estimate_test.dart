import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart';

/// The connection screen's slot count is the cached /status figure, less one
/// for the slot an /auth just took. A reused session (every auto-reconnect
/// inside the session's life) takes no new slot, but was counted as one, so
/// a reconnect loop walked the estimate down to zero.

void main() {
  test('a new session with TX takes a slot', () {
    expect(authTookNewSlot({'success': true, 'tx_allowed': true}), isTrue);
  });

  test('a reused session takes no slot', () {
    expect(
        authTookNewSlot(
            {'success': true, 'tx_allowed': true, 'resume_counter': 14}),
        isFalse);
  });

  test('a reused session with no pings yet still takes no slot', () {
    expect(
        authTookNewSlot(
            {'success': true, 'tx_allowed': true, 'resume_counter': 0}),
        isFalse);
  });

  test('no TX means no slot', () {
    expect(authTookNewSlot({'success': true, 'tx_allowed': false}), isFalse);
  });

  test('a server count is used as is, not adjusted', () {
    expect(
        authTookNewSlot(
            {'success': true, 'tx_allowed': true, 'slots_available': 3}),
        isFalse);
  });
}
