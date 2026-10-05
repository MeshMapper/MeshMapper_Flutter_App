import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/meshcore/buffer_utils.dart';
import 'package:mesh_mapper/services/meshcore/channel_service.dart';
import 'package:mesh_mapper/services/meshcore/connection.dart';
import 'package:mesh_mapper/services/meshcore/crypto_service.dart';
import 'package:mesh_mapper/services/meshcore/packet_parser.dart';
import 'package:mesh_mapper/services/meshcore/protocol_constants.dart';

import 'catalog_protocol_transport.dart';

/// One scripted answer to a CMD_GET_CHANNEL read.
sealed class _Answer {
  const _Answer();
}

class _Slot extends _Answer {
  final String name;
  final Uint8List key;
  const _Slot(this.name, this.key);
}

class _Err extends _Answer {
  final int code;
  const _Err(this.code);
}

class _Silent extends _Answer {
  const _Silent();
}

class _WriteFails extends _Answer {
  const _WriteFails();
}

/// The reply is held back, and from then on every reply runs one read
/// behind: each read gets the answer to the read before it.
class _Late extends _Answer {
  const _Late();
}

/// A reply for [staleIdx] arrives first, then the real answer.
class _StaleFirst extends _Answer {
  final int staleIdx;
  const _StaleFirst(this.staleIdx);
}

/// A radio whose channel table is [slots]; reads past it answer [endError].
/// MeshCore uses NOT_FOUND, while ZephCore uses ILLEGAL_ARG.
/// [faults] lists, per slot index, answers given before the real one.
class _ChannelRadio extends CatalogProtocolTransport {
  final List<_Slot> slots;
  final Map<int, List<_Answer>> faults;

  final int? advertisedChannels;
  final int endError;
  final int protocolVersion;

  _ChannelRadio(this.slots,
      {Map<int, List<_Answer>>? faults,
      this.advertisedChannels,
      this.endError = ErrorCodes.notFound,
      this.protocolVersion = 14})
      : faults = faults ?? {};

  final List<int> reads = [];

  /// Replies the radio still owes once a [_Late] answer starts the lag.
  List<List<int>>? _lagged;

  List<Uint8List> get setChannelWrites =>
      writes.where((w) => w.first == CommandCodes.setChannel).toList();

  @override
  Future<void> write(Uint8List data) async {
    if (data.first == CommandCodes.deviceQuery && advertisedChannels != null) {
      // Device-info layout shared by MeshCore and ZephCore. Capacity is byte 3,
      // distinct from max contacts and the four-byte BLE PIN next to it.
      final frame = BufferWriter();
      frame.writeBytes([
        ResponseCodes.deviceInfo,
        protocolVersion,
        175,
        advertisedChannels!,
        0x40,
        0xe2,
        1,
        0
      ]);
      frame.writeCString('2026 Sep 27', 12);
      frame.writeCString('Heltec Mesh Node T1', 40);
      frame.writeCString('1.17.6-zephcore', 20);
      frame.writeBytes([0, 1]);
      emit(frame.toBytes());
      return;
    }
    if (data.first == CommandCodes.setChannel) {
      writes.add(Uint8List.fromList(data));
      emit([ResponseCodes.ok]);
      return;
    }
    if (data.first != CommandCodes.getChannel) {
      await super.write(data);
      return;
    }
    final idx = data[1];
    reads.add(idx);
    final queued = faults[idx];
    final _Answer answer = (queued != null && queued.isNotEmpty)
        ? queued.removeAt(0)
        : idx < slots.length
            ? slots[idx]
            : _Err(endError);
    if (answer is _WriteFails) {
      throw StateError('GATT write failed');
    }
    writes.add(Uint8List.fromList(data));
    final lagged = _lagged;
    if (answer is _Late) {
      _lagged = [_frameFor(idx, idx < slots.length ? slots[idx] : null)];
      return;
    }
    if (lagged != null) {
      lagged.add(_frameFor(idx, idx < slots.length ? slots[idx] : null));
      emit(lagged.removeAt(0));
      return;
    }
    switch (answer) {
      case _Slot():
        emit(_frameFor(idx, answer));
      case _Err(:final code):
        emit([ResponseCodes.err, code]);
      case _StaleFirst(:final staleIdx):
        emit(_frameFor(staleIdx, slots[staleIdx]));
        emit(_frameFor(idx, slots[idx]));
      case _Silent():
      case _WriteFails():
      case _Late():
        break;
    }
  }

  /// The radio's reply to a read of [idx]: the slot, or ERR_CODE_NOT_FOUND
  /// past the end of the table.
  List<int> _frameFor(int idx, _Slot? slot) {
    if (slot == null) return [ResponseCodes.err, ErrorCodes.notFound];
    final frame = BufferWriter();
    frame.writeByte(ResponseCodes.channelInfo);
    frame.writeByte(idx);
    frame.writeCString(slot.name, 32);
    frame.writeBytes(slot.key);
    return frame.toBytes();
  }
}

void main() {
  final wardrivingKey = CryptoService.deriveChannelKey('#wardriving');
  final emptyKey = Uint8List(16);
  final otherKey = Uint8List.fromList(List<int>.filled(16, 7));

  _Slot named(String name) => _Slot(name, otherKey);
  final empty = _Slot('', emptyKey);
  final wardriving = _Slot('#wardriving', wardrivingKey);

  /// Runs the scan on a fake clock so the 5 s read timeout and the retry
  /// delay cost no wall time.
  ({ChannelInfo? result, Object? error}) scan(_ChannelRadio radio) {
    ChannelInfo? result;
    Object? error;
    fakeAsync((async) {
      final connection = MeshCoreConnection(transport: radio);
      final operation = radio.advertisedChannels == null
          ? ChannelService.ensureWardrivingChannel(connection)
          : connection
              .connect((_) async => null)
              .then((_) => connection.wardrivingChannel!);
      operation.then<void>((value) => result = value,
          onError: (Object e) => error = e);
      async.elapse(const Duration(minutes: 2));
      connection.dispose();
    });
    radio.dispose();
    return (result: result, error: error);
  }

  for (final count in [8, 40, 64, 255]) {
    for (final endError in [ErrorCodes.notFound, ErrorCodes.illegalArg]) {
      test('$count advertised slots never probe the end (ERR $endError)', () {
        final radio = _ChannelRadio(
          [named('Public'), ...List.filled(count - 1, empty)],
          advertisedChannels: count,
          endError: endError,
          protocolVersion: count == 8 ? 7 : 14,
        );
        final out = scan(radio);
        expect(out.error, isNull);
        expect(out.result?.channelIndex, 1);
        expect(radio.reads, List.generate(count, (i) => i));
        expect(radio.setChannelWrites.single[1], 1);
      });
    }
  }

  test('ZephCore report creates at slot 10 after reading all 40 slots', () {
    final radio = _ChannelRadio(
      [
        ...List.generate(10, (i) => named('channel$i')),
        ...List.filled(30, empty)
      ],
      advertisedChannels: 40,
      endError: ErrorCodes.illegalArg,
    );
    final out = scan(radio);
    expect(out.error, isNull);
    expect(out.result?.channelIndex, 10);
    expect(radio.reads, List.generate(40, (i) => i));
    expect(radio.setChannelWrites.single[1], 10);
  });

  for (final existing in [wardriving, _Slot('My mapping', wardrivingKey)]) {
    test('reuses ${existing.name} in the last advertised slot after holes', () {
      final radio = _ChannelRadio(
        [named('Public'), ...List.filled(38, empty), existing],
        advertisedChannels: 40,
        endError: ErrorCodes.illegalArg,
      );
      final out = scan(radio);
      expect(out.error, isNull);
      expect(out.result?.channelIndex, 39);
      expect(radio.setChannelWrites, isEmpty);
    });
  }

  test('a full advertised table fails without writing or probing past it', () {
    final radio = _ChannelRadio(List.filled(8, named('#other')),
        advertisedChannels: 8, endError: ErrorCodes.illegalArg);
    final out = scan(radio);
    expect(out.error.toString(), contains('No empty channel slots'));
    expect(radio.reads, List.generate(8, (i) => i));
    expect(radio.setChannelWrites, isEmpty);
  });

  for (final error in [ErrorCodes.notFound, ErrorCodes.illegalArg]) {
    test('ERR $error inside advertised capacity cannot truncate the scan', () {
      final radio = _ChannelRadio(
        [named('Public'), empty, named('#other'), wardriving],
        advertisedChannels: 4,
        faults: {
          2: [_Err(error), _Err(error)]
        },
      );
      final out = scan(radio);
      expect(out.error.toString(), contains('Please reconnect'));
      expect(radio.setChannelWrites, isEmpty);
      expect(radio.reads, [0, 1, 2, 2]);
    });
  }

  test('transient not-found inside capacity retries and finds existing channel',
      () {
    final radio = _ChannelRadio(
      [named('Public'), empty, named('#other'), wardriving],
      advertisedChannels: 4,
      faults: {
        2: [const _Err(ErrorCodes.notFound)]
      },
    );
    final out = scan(radio);
    expect(out.error, isNull);
    expect(out.result?.channelIndex, 3);
    expect(radio.setChannelWrites, isEmpty);
    expect(radio.reads, [0, 1, 2, 2, 3]);
  });

  test('zero capacity uses the legacy not-found fallback', () {
    final radio =
        _ChannelRadio([named('Public'), empty], advertisedChannels: 0);
    final out = scan(radio);
    expect(out.error, isNull);
    expect(out.result?.channelIndex, 1);
    expect(radio.reads, [0, 1, 2]);
  });

  test('a timeout at slot 3 is retried and the existing channel at 6 is found',
      () {
    final radio = _ChannelRadio([
      named('Public'),
      empty,
      named('#local'),
      named('#ottawa'),
      named('#test'),
      named('#foo'),
      wardriving,
    ], faults: {
      3: [const _Silent()],
    });
    final out = scan(radio);
    expect(out.error, isNull);
    expect(out.result!.channelIndex, 6);
    expect(radio.setChannelWrites, isEmpty);
    expect(radio.reads.where((i) => i == 3).length, 2);
  });

  test('a non-2 ERR at slot 3 is retried, then the channel is found', () {
    final radio = _ChannelRadio([
      named('Public'),
      empty,
      named('#local'),
      named('#ottawa'),
      wardriving,
    ], faults: {
      3: [const _Err(1)],
    });
    final out = scan(radio);
    expect(out.error, isNull);
    expect(out.result!.channelIndex, 4);
    expect(radio.setChannelWrites, isEmpty);
  });

  test('a write error at a slot is retried like any other failure', () {
    final radio = _ChannelRadio([
      named('Public'),
      empty,
      wardriving
    ], faults: {
      2: [const _WriteFails()],
    });
    final out = scan(radio);
    expect(out.error, isNull);
    expect(out.result!.channelIndex, 2);
    expect(radio.setChannelWrites, isEmpty);
  });

  test('a slot failing twice fails setup and creates nothing', () {
    final radio = _ChannelRadio([
      named('Public'),
      empty,
      named('#local'),
      named('#ottawa'),
      wardriving,
    ], faults: {
      3: [const _Silent(), const _Err(1)],
    });
    final out = scan(radio);
    expect(out.result, isNull);
    expect(out.error.toString(), contains('Please reconnect'));
    expect(out.error.toString(), isNot(contains('timed out')));
    expect(radio.setChannelWrites, isEmpty);
    expect(radio.reads.where((i) => i > 3), isEmpty);
  });

  test('ERR code 2 at slot 8 with no #wardriving creates in the first empty',
      () {
    final radio = _ChannelRadio([
      named('Public'),
      named('#a'),
      empty,
      named('#b'),
      empty,
      named('#c'),
      named('#d'),
      named('#e'),
    ]);
    final out = scan(radio);
    expect(out.error, isNull);
    expect(out.result!.channelIndex, 2);
    expect(out.result!.name, '#wardriving');
    expect(radio.reads.last, 8);
    expect(radio.setChannelWrites, hasLength(1));
    final write = radio.setChannelWrites.single;
    expect(write[1], 2);
  });

  test('a differently named channel with the #wardriving key is reused', () {
    final radio = _ChannelRadio([
      named('Public'),
      empty,
      _Slot('Wardrive', wardrivingKey),
    ]);
    final out = scan(radio);
    expect(out.error, isNull);
    expect(out.result!.channelIndex, 2);
    expect(out.result!.name, 'Wardrive');
    expect(radio.setChannelWrites, isEmpty);
  });

  test('a late reply after a timeout never shifts the scan onto a used slot',
      () {
    // Slot 1 times out and its reply arrives late; from then on every reply
    // runs one read behind. Taking replies in arrival order would record the
    // empty slot 3 as slot 4 and create #wardriving over the user's channel.
    final radio = _ChannelRadio([
      named('Public'),
      named('#a'),
      named('#b'),
      empty,
      named('#mine'),
    ], faults: {
      1: [const _Late()],
    });
    final out = scan(radio);
    expect(out.error, isNull);
    expect(out.result!.channelIndex, 3);
    expect(radio.setChannelWrites, hasLength(1));
    expect(radio.setChannelWrites.single[1], 3);
  });

  test('a stale reply for another slot is ignored and the right one taken', () {
    final radio = _ChannelRadio([
      named('Public'),
      named('#a'),
      empty
    ], faults: {
      2: [const _StaleFirst(1)],
    });
    ChannelInfo? result;
    fakeAsync((async) {
      final connection = MeshCoreConnection(transport: radio);
      connection.getChannel(2).then<void>((value) => result = value);
      async.elapse(const Duration(seconds: 1));
      connection.dispose();
    });
    radio.dispose();
    expect(result, isNotNull);
    expect(result!.channelIndex, 2);
    expect(result!.name, '');
  });

  test('the typed command error still reads as before in logs', () {
    expect(const CommandErrorException(3).toString(),
        'Exception: Command error (code 3)');
  });
}
