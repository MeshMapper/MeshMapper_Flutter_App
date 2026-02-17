import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// Buffer reader for parsing binary data from MeshCore devices
/// Ported from content/mc/buffer_reader.js in WebClient repo
class BufferReader {
  final Uint8List _buffer;
  int _pointer = 0;

  BufferReader(List<int> data) : _buffer = Uint8List.fromList(data);

  /// Get remaining bytes count
  int get remainingBytesCount => _buffer.length - _pointer;

  /// Check if there are more bytes to read
  bool get hasMoreBytes => _pointer < _buffer.length;

  /// Read a single byte
  int readByte() {
    if (_pointer >= _buffer.length) {
      throw RangeError('Buffer underflow: no more bytes to read');
    }
    return _buffer[_pointer++];
  }

  /// Read multiple bytes
  Uint8List readBytes(int count) {
    if (_pointer + count > _buffer.length) {
      throw RangeError('Buffer underflow: not enough bytes to read');
    }
    final data = _buffer.sublist(_pointer, _pointer + count);
    _pointer += count;
    return data;
  }

  /// Read all remaining bytes
  Uint8List readRemainingBytes() {
    return readBytes(remainingBytesCount);
  }

  /// Read remaining bytes as UTF-8 string
  /// Uses allowMalformed to handle any non-UTF-8 bytes gracefully
  String readString() {
    return utf8.decode(readRemainingBytes(), allowMalformed: true);
  }

  /// Read null-terminated string with max length
  /// Uses allowMalformed to handle firmware padding bytes that aren't valid UTF-8
  String readCString(int maxLength) {
    final bytes = <int>[];
    final rawBytes = readBytes(maxLength);

    for (final byte in rawBytes) {
      if (byte == 0) {
        return utf8.decode(Uint8List.fromList(bytes), allowMalformed: true);
      }
      bytes.add(byte);
    }

    return utf8.decode(Uint8List.fromList(bytes), allowMalformed: true);
  }

  /// Read signed 8-bit integer
  int readInt8() {
    final byte = readByte();
    // Convert unsigned to signed
    return byte > 127 ? byte - 256 : byte;
  }

  /// Read unsigned 8-bit integer
  int readUInt8() {
    return readByte();
  }

  /// Read unsigned 16-bit integer (little-endian)
  int readUInt16LE() {
    final bytes = readBytes(2);
    return bytes[0] | (bytes[1] << 8);
  }

  /// Read unsigned 32-bit integer (little-endian)
  int readUInt32LE() {
    final bytes = readBytes(4);
    return bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24);
  }

  /// Read unsigned 32-bit integer (big-endian)
  int readUInt32BE() {
    final bytes = readBytes(4);
    return (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
  }

  /// Read signed 16-bit integer (little-endian)
  int readInt16LE() {
    final value = readUInt16LE();
    return value > 32767 ? value - 65536 : value;
  }

  /// Read signed 32-bit integer (little-endian)
  int readInt32LE() {
    final value = readUInt32LE();
    // Handle signed conversion for 32-bit
    if (value > 0x7FFFFFFF) {
      return value - 0x100000000;
    }
    return value;
  }

}

/// Buffer writer for creating binary data for MeshCore devices
/// Ported from content/mc/buffer_writer.js in WebClient repo
class BufferWriter {
  final List<int> _buffer = [];

  /// Get the written bytes as Uint8List
  Uint8List toBytes() {
    return Uint8List.fromList(_buffer);
  }

  /// Get current length
  int get length => _buffer.length;

  /// Write raw bytes
  void writeBytes(List<int> bytes) {
    _buffer.addAll(bytes);
  }

  /// Write a single byte
  void writeByte(int byte) {
    _buffer.add(byte & 0xFF);
  }

  /// Write unsigned 16-bit integer (little-endian)
  void writeUInt16LE(int num) {
    _buffer.add(num & 0xFF);
    _buffer.add((num >> 8) & 0xFF);
  }

  /// Write unsigned 32-bit integer (little-endian)
  void writeUInt32LE(int num) {
    _buffer.add(num & 0xFF);
    _buffer.add((num >> 8) & 0xFF);
    _buffer.add((num >> 16) & 0xFF);
    _buffer.add((num >> 24) & 0xFF);
  }

  /// Write UTF-8 string
  void writeString(String string) {
    writeBytes(utf8.encode(string));
  }

  /// Write null-terminated string with fixed max length
  void writeCString(String string, int maxLength) {
    final encoded = utf8.encode(string);
    final bytes = Uint8List(maxLength);
    
    // Copy string bytes up to maxLength - 1
    final copyLength = math.min(encoded.length, maxLength - 1);
    for (int i = 0; i < copyLength; i++) {
      bytes[i] = encoded[i];
    }
    
    // Ensure last byte is null terminator
    bytes[maxLength - 1] = 0;
    
    writeBytes(bytes);
  }

  /// Clear the buffer
  void clear() {
    _buffer.clear();
  }
}
