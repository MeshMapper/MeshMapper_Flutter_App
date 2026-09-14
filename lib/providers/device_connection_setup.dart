import '../models/connection_state.dart';
import '../models/device_model.dart';
import '../models/user_preferences.dart';
import '../services/device_model_service.dart';
import '../services/meshcore/connection.dart';
import '../services/reporting_power.dart';

/// Replaces the previous radio's power flags using this radio's saved choice.
/// Used before online auth and after connection in both online and Offline Mode.
UserPreferences preferencesForConnectingDevice({
  required UserPreferences preferences,
  required DeviceModel? model,
  required String? deviceName,
  required Map<String, Map<String, dynamic>> savedOverrides,
}) {
  final resolved = resolveReportingPower(
    model: model,
    savedOverride: deviceName == null ? null : savedOverrides[deviceName],
  );
  return preferences.copyWith(
    powerLevel: resolved.power,
    txPower: resolved.txPower,
    autoPowerSet: resolved.autoSet,
    powerLevelSet: resolved.configured,
  );
}

/// Applies the provider's catalog decisions after a successful real handshake.
/// Unknown reporting remains asynchronous and cannot affect transport state.
UserPreferences prepareConnectedDevice({
  required UserPreferences preferences,
  required MeshCoreConnection connection,
  required DeviceModelService catalog,
  required String? deviceName,
  required Map<String, Map<String, dynamic>> savedOverrides,
  required String appVersion,
}) {
  if (connection.currentStep != ConnectionStep.connected) return preferences;
  final updated = preferencesForConnectingDevice(
    preferences: preferences,
    model: connection.deviceModel,
    deviceName: deviceName,
    savedOverrides: savedOverrides,
  );
  final info = connection.deviceInfo;
  if (connection.deviceModel == null && info != null) {
    catalog.observeUnknownDevice(
      manufacturer: info.manufacturer,
      appVersion: appVersion,
      firmwareVersion: info.firmwareVersionString,
    );
  }
  return updated;
}
