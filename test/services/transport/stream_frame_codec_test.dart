import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/transport/stream_frame_codec.dart';

void main() {
  late StreamFrameCodec codec;
  late List<Uint8List> receivedFrames;

  setUp(() {
    codec = StreamFrameCodec();
    receivedFrames = [];
    codec.frames.listen((frame) => receivedFrames.add(frame));
  });

  tearDown(() {
    codec.dispose();
  });

  Uint8List makeIncomingFrame(List<int> payload) {
    final frame = Uint8List(3 + payload.length);
    frame[0] = StreamFrameCodec.incomingMarker; // 0x3E
    frame[1] = payload.length & 0xFF;
    frame[2] = (payload.length >> 8) & 0xFF;
    frame.setRange(3, frame.length, payload);
    return frame;
  }

  group('encode', () {
    test('prepends outgoing marker and length', () {
      final payload = Uint8List.fromList([0x01, 0x02, 0x03]);
      final encoded = StreamFrameCodec.encode(payload);

      expect(encoded.length, 6);
      expect(encoded[0], StreamFrameCodec.outgoingMarker); // 0x3C
      expect(encoded[1], 3); // length low byte
      expect(encoded[2], 0); // length high byte
      expect(encoded.sublist(3), payload);
    });

    test('handles max TX payload (172 bytes)', () {
      final payload = Uint8List(172);
      final encoded = StreamFrameCodec.encode(payload);

      expect(encoded.length, 175);
      expect(encoded[0], StreamFrameCodec.outgoingMarker);
      expect(encoded[1], 172); // 0xAC
      expect(encoded[2], 0);
    });

    test('encodes length as little-endian uint16', () {
      final payload = Uint8List(100);
      final encoded = StreamFrameCodec.encode(payload);

      expect(encoded[1], 100);
      expect(encoded[2], 0);
    });

    test('handles single-byte payload', () {
      final payload = Uint8List.fromList([0xFF]);
      final encoded = StreamFrameCodec.encode(payload);

      expect(encoded.length, 4);
      expect(encoded[3], 0xFF);
    });
  });

  group('addBytes - single frame', () {
    test('decodes a complete frame', () async {
      final frame = makeIncomingFrame([0x01, 0x02, 0x03]);
      codec.addBytes(frame);
      await Future.delayed(Duration.zero);

      expect(receivedFrames.length, 1);
      expect(receivedFrames[0], Uint8List.fromList([0x01, 0x02, 0x03]));
    });

    test('decodes frame with max RX payload (300 bytes)', () async {
      final payload = List.generate(300, (i) => i & 0xFF);
      final frame = makeIncomingFrame(payload);
      codec.addBytes(frame);
      await Future.delayed(Duration.zero);

      expect(receivedFrames.length, 1);
      expect(receivedFrames[0].length, 300);
    });
  });

  group('addBytes - multiple frames in one chunk', () {
    test('extracts two frames from one chunk', () async {
      final frame1 = makeIncomingFrame([0xAA]);
      final frame2 = makeIncomingFrame([0xBB, 0xCC]);
      final combined = Uint8List.fromList([...frame1, ...frame2]);

      codec.addBytes(combined);
      await Future.delayed(Duration.zero);

      expect(receivedFrames.length, 2);
      expect(receivedFrames[0], Uint8List.fromList([0xAA]));
      expect(receivedFrames[1], Uint8List.fromList([0xBB, 0xCC]));
    });

    test('extracts three frames from one chunk', () async {
      final frame1 = makeIncomingFrame([0x01]);
      final frame2 = makeIncomingFrame([0x02]);
      final frame3 = makeIncomingFrame([0x03]);
      final combined =
          Uint8List.fromList([...frame1, ...frame2, ...frame3]);

      codec.addBytes(combined);
      await Future.delayed(Duration.zero);

      expect(receivedFrames.length, 3);
    });
  });

  group('addBytes - partial frames across chunks', () {
    test('header split across two chunks', () async {
      final frame = makeIncomingFrame([0x01, 0x02, 0x03]);

      // Send marker + first length byte
      codec.addBytes(Uint8List.fromList(frame.sublist(0, 2)));
      await Future.delayed(Duration.zero);
      expect(receivedFrames.length, 0);

      // Send rest
      codec.addBytes(Uint8List.fromList(frame.sublist(2)));
      await Future.delayed(Duration.zero);
      expect(receivedFrames.length, 1);
      expect(receivedFrames[0], Uint8List.fromList([0x01, 0x02, 0x03]));
    });

    test('one byte at a time', () async {
      final frame = makeIncomingFrame([0xAA, 0xBB]);

      for (int i = 0; i < frame.length; i++) {
        codec.addBytes(Uint8List.fromList([frame[i]]));
        await Future.delayed(Duration.zero);
      }

      expect(receivedFrames.length, 1);
      expect(receivedFrames[0], Uint8List.fromList([0xAA, 0xBB]));
    });

    test('payload split across two chunks', () async {
      final frame = makeIncomingFrame([0x01, 0x02, 0x03, 0x04, 0x05]);

      // Send header + partial payload
      codec.addBytes(Uint8List.fromList(frame.sublist(0, 5)));
      await Future.delayed(Duration.zero);
      expect(receivedFrames.length, 0);

      // Send remaining payload
      codec.addBytes(Uint8List.fromList(frame.sublist(5)));
      await Future.delayed(Duration.zero);
      expect(receivedFrames.length, 1);
      expect(receivedFrames[0],
          Uint8List.fromList([0x01, 0x02, 0x03, 0x04, 0x05]));
    });
  });

  group('addBytes - junk byte handling', () {
    test('discards junk bytes before marker', () async {
      final junk = [0x41, 0x42, 0x43]; // "ABC" debug text
      final frame = makeIncomingFrame([0x01]);
      final combined = Uint8List.fromList([...junk, ...frame]);

      codec.addBytes(combined);
      await Future.delayed(Duration.zero);

      expect(receivedFrames.length, 1);
      expect(receivedFrames[0], Uint8List.fromList([0x01]));
    });

    test('discards all bytes when no marker present', () async {
      codec.addBytes(Uint8List.fromList([0x41, 0x42, 0x43, 0x44]));
      await Future.delayed(Duration.zero);

      expect(receivedFrames.length, 0);
    });

    test('handles junk between two frames', () async {
      final frame1 = makeIncomingFrame([0xAA]);
      final junk = [0x44, 0x45, 0x42, 0x55, 0x47]; // "DEBUG"
      final frame2 = makeIncomingFrame([0xBB]);
      final combined =
          Uint8List.fromList([...frame1, ...junk, ...frame2]);

      codec.addBytes(combined);
      await Future.delayed(Duration.zero);

      expect(receivedFrames.length, 2);
      expect(receivedFrames[0], Uint8List.fromList([0xAA]));
      expect(receivedFrames[1], Uint8List.fromList([0xBB]));
    });
  });

  group('addBytes - invalid frames', () {
    test('skips zero-length frame', () async {
      // Zero-length frame: marker + [0x00, 0x00]
      final zeroFrame = Uint8List.fromList([0x3E, 0x00, 0x00]);
      final validFrame = makeIncomingFrame([0x01]);
      final combined = Uint8List.fromList([...zeroFrame, ...validFrame]);

      codec.addBytes(combined);
      await Future.delayed(Duration.zero);

      expect(receivedFrames.length, 1);
      expect(receivedFrames[0], Uint8List.fromList([0x01]));
    });

    test('skips oversized frame (>300 bytes)', () async {
      // Frame claiming 301 bytes: marker + [0x2D, 0x01] = 301
      final oversizedHeader = Uint8List.fromList([0x3E, 0x2D, 0x01]);
      final validFrame = makeIncomingFrame([0x42]);
      final combined =
          Uint8List.fromList([...oversizedHeader, ...validFrame]);

      codec.addBytes(combined);
      await Future.delayed(Duration.zero);

      expect(receivedFrames.length, 1);
      expect(receivedFrames[0], Uint8List.fromList([0x42]));
    });
  });

  group('addBytes - edge cases', () {
    test('empty addBytes is a no-op', () async {
      codec.addBytes(Uint8List(0));
      await Future.delayed(Duration.zero);

      expect(receivedFrames.length, 0);
    });

    test('only marker byte, then rest later', () async {
      codec.addBytes(Uint8List.fromList([0x3E]));
      await Future.delayed(Duration.zero);
      expect(receivedFrames.length, 0);

      codec.addBytes(Uint8List.fromList([0x02, 0x00, 0xAA, 0xBB]));
      await Future.delayed(Duration.zero);
      expect(receivedFrames.length, 1);
      expect(receivedFrames[0], Uint8List.fromList([0xAA, 0xBB]));
    });

    test('reset clears buffer state', () async {
      // Send partial frame
      final frame = makeIncomingFrame([0x01, 0x02, 0x03]);
      codec.addBytes(Uint8List.fromList(frame.sublist(0, 2)));
      await Future.delayed(Duration.zero);
      expect(receivedFrames.length, 0);

      // Reset
      codec.reset();

      // Send a complete new frame
      final newFrame = makeIncomingFrame([0xFF]);
      codec.addBytes(newFrame);
      await Future.delayed(Duration.zero);
      expect(receivedFrames.length, 1);
      expect(receivedFrames[0], Uint8List.fromList([0xFF]));
    });
  });

  group('encode/decode round-trip', () {
    test('encode then decode produces original payload', () async {
      final original = Uint8List.fromList([0x16, 0x01, 0x4D, 0x65, 0x73]);
      final encoded = StreamFrameCodec.encode(original);

      // Simulate what the device would do: change the marker from 0x3C to 0x3E
      // (device echoes back with incoming marker)
      final incoming = Uint8List.fromList(encoded);
      incoming[0] = StreamFrameCodec.incomingMarker;

      codec.addBytes(incoming);
      await Future.delayed(Duration.zero);

      expect(receivedFrames.length, 1);
      expect(receivedFrames[0], original);
    });
  });
}
