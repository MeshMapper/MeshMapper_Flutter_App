/// MeshCore protocol constants
/// Ported from content/mc/constants.js in WebClient repo
/// CRITICAL: These values must match exactly for device compatibility
class ProtocolConstants {
  ProtocolConstants._();

  /// Supported companion protocol version
  static const int supportedCompanionProtocolVersion = 1;

  /// Serial frame types
  static const int serialFrameTypeIncoming = 0x3e; // ">"
  static const int serialFrameTypeOutgoing = 0x3c; // "<"
}

/// BLE GATT UUIDs for MeshCore devices
class BleUuids {
  BleUuids._();

  /// Nordic UART Service UUID
  static const String serviceUuid = '6E400001-B5A3-F393-E0A9-E50E24DCCA9E';
  
  /// RX Characteristic (we write to this, device reads from it)
  static const String characteristicRxUuid = '6E400002-B5A3-F393-E0A9-E50E24DCCA9E';
  
  /// TX Characteristic (device writes to this, we read from it)
  static const String characteristicTxUuid = '6E400003-B5A3-F393-E0A9-E50E24DCCA9E';
}

/// Command codes sent to device
class CommandCodes {
  CommandCodes._();

  static const int appStart = 1;
  static const int sendTxtMsg = 2;
  static const int sendChannelTxtMsg = 3;
  static const int getContacts = 4;
  static const int getDeviceTime = 5;
  static const int setDeviceTime = 6;
  static const int sendSelfAdvert = 7;
  static const int setAdvertName = 8;
  static const int addUpdateContact = 9;
  static const int syncNextMessage = 10;
  static const int setRadioParams = 11;
  static const int setTxPower = 12;
  static const int resetPath = 13;
  static const int setAdvertLatLon = 14;
  static const int removeContact = 15;
  static const int shareContact = 16;
  static const int exportContact = 17;
  static const int importContact = 18;
  static const int reboot = 19;
  static const int getBatteryVoltage = 20;
  static const int setTuningParams = 21;
  static const int deviceQuery = 22;
  static const int exportPrivateKey = 23;
  static const int importPrivateKey = 24;
  static const int sendRawData = 25;
  static const int sendLogin = 26;
  static const int sendStatusReq = 27;
  static const int getChannel = 31;
  static const int setChannel = 32;
  static const int signStart = 33;
  static const int signData = 34;
  static const int signFinish = 35;
  static const int sendTracePath = 36;
  static const int setOtherParams = 38;
  static const int sendTelemetryReq = 39;
  static const int getStats = 56; // 0x38
  static const int sendBinaryReq = 50;
}

/// Response codes received from device
class ResponseCodes {
  ResponseCodes._();

  static const int ok = 0;
  static const int err = 1;
  static const int contactsStart = 2;
  static const int contact = 3;
  static const int endOfContacts = 4;
  static const int selfInfo = 5;
  static const int sent = 6;
  static const int contactMsgRecv = 7;
  static const int channelMsgRecv = 8;
  static const int currTime = 9;
  static const int noMoreMessages = 10;
  static const int exportContact = 11;
  static const int batteryVoltage = 12;
  static const int deviceInfo = 13;
  static const int privateKey = 14;
  static const int disabled = 15;
  static const int channelInfo = 18;
  static const int signStart = 19;
  static const int signature = 20;
  static const int stats = 24; // 0x18
}

/// Push codes (unsolicited messages from device)
class PushCodes {
  PushCodes._();

  static const int advert = 0x80;
  static const int pathUpdated = 0x81;
  static const int sendConfirmed = 0x82;
  static const int msgWaiting = 0x83;
  static const int rawData = 0x84;
  static const int loginSuccess = 0x85;
  static const int loginFail = 0x86;
  static const int statusResponse = 0x87;
  static const int logRxData = 0x88;
  static const int traceData = 0x89;
  static const int newAdvert = 0x8A;
  static const int telemetryResponse = 0x8B;
  static const int binaryResponse = 0x8C;
}

/// Error codes from device
class ErrorCodes {
  ErrorCodes._();

  static const int unsupportedCmd = 1;
  static const int notFound = 2;
  static const int tableFull = 3;
  static const int badState = 4;
  static const int fileIoError = 5;
  static const int illegalArg = 6;
}

/// Advertisement types
class AdvType {
  AdvType._();

  static const int none = 0;
  static const int chat = 1;
  static const int repeater = 2;
  static const int room = 3;
}

/// Self advertisement types
class SelfAdvertTypes {
  SelfAdvertTypes._();

  static const int zeroHop = 0;
  static const int flood = 1;
}

/// Text message types
class TxtTypes {
  TxtTypes._();

  static const int plain = 0;
  static const int cliData = 1;
  static const int signedPlain = 2;
}

/// Binary request types
class BinaryRequestTypes {
  BinaryRequestTypes._();

  static const int getTelemetryData = 0x03;
  static const int getAvgMinMax = 0x04;
  static const int getAccessList = 0x05;
  static const int getNeighbours = 0x06;
}

/// Stats types for GetStats command
class StatsTypes {
  StatsTypes._();

  static const int core = 0;
  static const int radio = 1;
  static const int packets = 2;
}

/// Packet header constants
class PacketHeader {
  PacketHeader._();

  static const int routeMask = 0x03;   // 2-bits
  static const int typeShift = 2;
  static const int typeMask = 0x0F;    // 4-bits
  static const int verShift = 6;
  static const int verMask = 0x03;     // 2-bits
}

/// Route types
class RouteType {
  RouteType._();

  static const int reserved1 = 0x00;
  static const int flood = 0x01;
  static const int direct = 0x02;
  static const int reserved2 = 0x03;
}

/// Payload types
class PayloadType {
  PayloadType._();

  static const int req = 0x00;
  static const int response = 0x01;
  static const int txtMsg = 0x02;
  static const int ack = 0x03;
  static const int advert = 0x04;
  static const int grpTxt = 0x05;
  static const int grpData = 0x06;
  static const int anonReq = 0x07;
  static const int path = 0x08;
  static const int trace = 0x09;
  static const int rawCustom = 0x0F;
}
