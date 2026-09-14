import '../models/device_model.dart';

/// The reporting values selected for one connected radio.
class ReportingPower {
  final double? power;
  final int? txPower;
  final bool autoSet;
  final bool configured;

  const ReportingPower({
    required this.power,
    required this.txPower,
    required this.autoSet,
    required this.configured,
  });
}

/// Resolves the reporting-only power with the per-radio override precedence.
ReportingPower resolveReportingPower({
  required DeviceModel? model,
  Map<String, dynamic>? savedOverride,
}) {
  if (savedOverride != null &&
      savedOverride['powerLevel'] is num &&
      savedOverride['txPower'] is num) {
    return ReportingPower(
      power: (savedOverride['powerLevel'] as num).toDouble(),
      txPower: (savedOverride['txPower'] as num).toInt(),
      autoSet: false,
      configured: true,
    );
  }
  if (model != null) {
    return ReportingPower(
      power: model.power,
      txPower: model.txPower,
      autoSet: true,
      configured: false,
    );
  }
  return const ReportingPower(
    power: null,
    txPower: null,
    autoSet: false,
    configured: false,
  );
}
