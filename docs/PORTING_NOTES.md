# Porting Notes: JavaScript to Dart

This document describes key decisions and patterns used when porting the MeshMapper WebClient from JavaScript to Flutter/Dart.

## Source Files Ported

| JavaScript Source | Dart Target | Notes |
|------------------|-------------|-------|
| `content/mc/constants.js` | `lib/services/meshcore/protocol_constants.dart` | All constants preserved as static class members |
| `content/mc/buffer_reader.js` | `lib/services/meshcore/buffer_utils.dart` | BufferReader class with identical API |
| `content/mc/buffer_writer.js` | `lib/services/meshcore/buffer_utils.dart` | BufferWriter class with identical API |
| `content/mc/packet.js` | `lib/services/meshcore/packet_parser.dart` | Packet parsing with typed results |
| `content/mc/connection/connection.js` | `lib/services/meshcore/connection.dart` | Command/response handling |
| `content/mc/connection/web_ble_connection.js` | `lib/services/bluetooth/*.dart` | Split into mobile and web implementations |
| `content/device-models.json` | `assets/device-models.json` | Identical JSON structure |
| `content/wardrive.js` | Multiple service files | Split into logical services |

## Key Translation Patterns

### 1. JavaScript Classes → Dart Classes

JavaScript:
```javascript
class BufferReader {
    constructor(data) {
        this.pointer = 0;
        this.buffer = new Uint8Array(data);
    }
}
```

Dart:
```dart
class BufferReader {
  final Uint8List _buffer;
  int _pointer = 0;

  BufferReader(List<int> data) : _buffer = Uint8List.fromList(data);
}
```

### 2. JavaScript Callbacks → Dart Streams

JavaScript (EventEmitter pattern):
```javascript
connection.on('channelMsgRecv', (msg) => { ... });
```

Dart (Stream pattern):
```dart
connection.channelMessageStream.listen((msg) { ... });
```

### 3. JavaScript Promises → Dart Futures

JavaScript:
```javascript
async function connect() {
    await bluetooth.connect();
}
```

Dart:
```dart
Future<void> connect() async {
    await bluetooth.connect();
}
```

### 4. JavaScript Object Literals → Dart Classes

JavaScript:
```javascript
const result = {
    snr: reader.readInt8() / 4,
    rssi: reader.readInt8(),
    text: reader.readString(),
};
```

Dart:
```dart
class ChannelMessage {
  final double snr;
  final int rssi;
  final String text;
}
```

### 5. JavaScript Timer Functions → Dart Timer

JavaScript:
```javascript
setTimeout(() => { ... }, 6000);
setInterval(() => { ... }, 30000);
```

Dart:
```dart
Timer(Duration(seconds: 6), () { ... });
Timer.periodic(Duration(seconds: 30), (_) { ... });
```

## Binary Data Handling

### Uint8Array → Uint8List

JavaScript arrays are replaced with Dart's typed data:

```dart
import 'dart:typed_data';

// Reading
final bytes = Uint8List.fromList([0x01, 0x02, 0x03]);

// Writing
final buffer = ByteData(4);
buffer.setUint32(0, value, Endian.little);
```

### Little-Endian vs Big-Endian

The JavaScript implementation uses DataView with explicit endianness. In Dart:

```dart
// Little-endian read (same as JS with `true` parameter)
int readUInt32LE() {
  final bytes = readBytes(4);
  return bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24);
}
```

## State Management

The monolithic `wardrive.js` file was split into:

1. **Services** (business logic):
   - `GpsService` - Location tracking
   - `PingService` - TX/RX orchestration
   - `ApiQueueService` - Upload queue

2. **Providers** (UI state):
   - `AppStateProvider` - Combines all state for UI

This follows Flutter's recommended separation of concerns.

## Platform Abstraction

### Web vs Mobile Bluetooth

JavaScript used Web Bluetooth API directly. In Flutter:

```dart
// Abstract interface
abstract class BluetoothService {
  Future<void> connect(String deviceId);
  Future<void> write(Uint8List data);
}

// Platform selection
final bluetooth = kIsWeb 
    ? WebBluetoothService() 
    : MobileBluetoothService();
```

## Persistence

### localStorage → Hive

JavaScript:
```javascript
localStorage.setItem('queue', JSON.stringify(items));
```

Dart (Hive):
```dart
final box = await Hive.openBox<ApiQueueItem>('api_queue');
await box.add(item);
```

Hive provides:
- Type safety with adapters
- Better performance
- Works on all platforms

## Error Handling

JavaScript's loose error handling was replaced with Dart's try-catch:

```dart
try {
  await connection.connect(deviceId);
} on TimeoutException catch (e) {
  // Handle timeout specifically
} catch (e) {
  // Handle other errors
}
```

## Testing Considerations

The JavaScript implementation had minimal testing. The Dart port includes:

1. Unit tests for services
2. Integration tests for workflows
3. Hardware validation tests (manual)

## Known Differences

1. **No Direct DOM Access**: Flutter uses its own rendering, so all Tailwind CSS was replaced with Material Design widgets.

2. **No eval()**: All dynamic code execution was replaced with static patterns.

3. **Null Safety**: Dart's null safety required explicit handling of optional values that JavaScript treated implicitly.

4. **Async Patterns**: JavaScript's single-threaded event loop maps well to Dart's event loop, but Isolates are available for heavy computation if needed.

## Protocol Compatibility

**CRITICAL**: The binary protocol MUST match exactly:
- Command codes unchanged
- Response parsing unchanged
- Byte order preserved
- String encoding (UTF-8) preserved

All buffer utilities were tested against JavaScript implementation to ensure byte-for-byte compatibility.
