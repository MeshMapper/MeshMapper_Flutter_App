import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/scope_log_entry.dart';

/// `AppStateProvider` cannot be constructed in this suite (it opens Hive
/// boxes, BLE and GPS in its constructor), so `clearLogs`/`clearPings`
/// clearing scope entries cannot be driven through the provider directly.
/// `ScopeLogStore` is the class the provider owns and delegates
/// `_addScopeLogEntry`/`clearLogs`/`clearPings` to (each a one-line call:
/// `_scopeLog.add(entry)`, `_scopeLog.clear()`), so exercising this store's
/// own add/cap/clear is exercising the actual clearing behavior those three
/// call sites depend on.
ScopeLogEntry _entry(DateTime timestamp) => ScopeLogEntry(
      timestamp: timestamp,
      latitude: 45.1,
      longitude: -75.2,
      repeaterId: 'AB',
      pubkeyHex: 'AB' * 32,
      outcome: ScopeLogOutcome.answered,
      scopes: const ['Ottawa'],
    );

void main() {
  test('starts empty', () {
    expect(ScopeLogStore().entries, isEmpty);
  });

  test('add inserts newest first', () {
    final store = ScopeLogStore();
    final first = _entry(DateTime(2026, 9, 26, 9));
    final second = _entry(DateTime(2026, 9, 26, 10));

    store.add(first);
    store.add(second);

    expect(store.entries, [second, first]);
  });

  test('caps at maxEntries, dropping the oldest', () {
    final store = ScopeLogStore(maxEntries: 3);
    final e0 = _entry(DateTime(2026, 9, 26, 9, 0));
    final e1 = _entry(DateTime(2026, 9, 26, 9, 1));
    final e2 = _entry(DateTime(2026, 9, 26, 9, 2));
    final e3 = _entry(DateTime(2026, 9, 26, 9, 3));

    store.add(e0);
    store.add(e1);
    store.add(e2);
    expect(store.entries, hasLength(3));

    store.add(e3);
    expect(store.entries, hasLength(3));
    expect(store.entries, [e3, e2, e1]);
    expect(store.entries.contains(e0), isFalse);
  });

  test('defaults to the app-wide 500 cap', () {
    final store = ScopeLogStore();
    expect(store.maxEntries, 500);
  });

  test('clear empties the store, this is what clearLogs/clearPings call', () {
    final store = ScopeLogStore();
    store.add(_entry(DateTime(2026, 9, 26, 9)));
    store.add(_entry(DateTime(2026, 9, 26, 10)));
    expect(store.entries, isNotEmpty);

    store.clear();

    expect(store.entries, isEmpty);
  });

  test('entries is unmodifiable', () {
    final store = ScopeLogStore();
    store.add(_entry(DateTime(2026, 9, 26, 9)));
    expect(() => store.entries.add(_entry(DateTime(2026, 9, 26, 10))),
        throwsUnsupportedError);
  });
}
