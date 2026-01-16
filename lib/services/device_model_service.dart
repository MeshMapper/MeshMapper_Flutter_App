import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/device_model.dart';

/// Device model service for auto-power selection
/// Ported from parseDeviceModel() and autoSetPowerLevel() in wardrive.js
/// 
/// CRITICAL: Correct power configuration is essential for PA amplifier models
/// to prevent hardware damage.
class DeviceModelService {
  List<DeviceModel> _models = [];
  Map<String, String> _powerMapping = {};
  bool _isLoaded = false;

  /// Check if models are loaded
  bool get isLoaded => _isLoaded;

  /// Get all loaded device models
  List<DeviceModel> get models => List.unmodifiable(_models);

  /// Load device models from assets
  Future<void> loadModels() async {
    if (_isLoaded) return;

    try {
      final jsonString = await rootBundle.loadString('assets/device-models.json');
      final jsonData = json.decode(jsonString) as Map<String, dynamic>;
      
      final database = DeviceModelsDatabase.fromJson(jsonData);
      _models = database.devices;
      _powerMapping = database.powerMapping;
      _isLoaded = true;
    } catch (e) {
      // If loading fails, use empty list (will default to safe power settings)
      _models = [];
      _powerMapping = {};
      _isLoaded = true;
    }
  }

  /// Match device manufacturer string to known model
  /// Reference: parseDeviceModel() in wardrive.js
  /// 
  /// Strips build suffix (e.g., "nightly-e31c46f") and matches against database
  DeviceModel? matchDevice(String manufacturerString) {
    if (_models.isEmpty) return null;

    // Clean up manufacturer string
    // Strip build suffix like "nightly-e31c46f"
    String cleanManufacturer = manufacturerString;
    final suffixPatterns = [
      RegExp(r'\s+nightly-[a-f0-9]+$', caseSensitive: false),
      RegExp(r'\s+stable-[a-f0-9]+$', caseSensitive: false),
      RegExp(r'\s+dev-[a-f0-9]+$', caseSensitive: false),
    ];
    for (final pattern in suffixPatterns) {
      cleanManufacturer = cleanManufacturer.replaceAll(pattern, '');
    }

    // Try exact match first
    for (final model in _models) {
      if (manufacturerString.contains(model.manufacturer) ||
          cleanManufacturer.contains(model.manufacturer)) {
        return model;
      }
    }

    // Try partial match on manufacturer string parts
    final parts = cleanManufacturer.split(RegExp(r'[\s\-_()]+'));
    for (final model in _models) {
      final modelParts = model.manufacturer.split(RegExp(r'[\s\-_()]+'));
      
      // Check if key identifying parts match
      int matchCount = 0;
      for (final modelPart in modelParts) {
        if (parts.any((p) => p.toLowerCase() == modelPart.toLowerCase())) {
          matchCount++;
        }
      }
      
      // Require at least 2 matching parts
      if (matchCount >= 2) {
        return model;
      }
    }

    return null;
  }

  /// Get recommended power setting for a device
  /// 
  /// CRITICAL: PA amplifier models require specific power values:
  /// - 33dBm models: power=2.0, txPower=9dBm
  /// - 30dBm models: power=1.0, txPower=20dBm
  /// - Standard models: power=0.3, txPower varies
  double getRecommendedPower(DeviceModel model) {
    return model.power;
  }

  /// Get recommended TX power (dBm) for a device
  int getRecommendedTxPower(DeviceModel model) {
    return model.txPower;
  }

  /// Get default (safe) power value for unknown devices
  /// Conservative setting to prevent hardware damage
  static const double defaultPower = 0.3;
  static const int defaultTxPower = 22;

  /// Get human-readable power description
  String getPowerDescription(double power) {
    final key = power.toString();
    return _powerMapping[key] ?? 'Unknown power level';
  }

  /// Check if a power level is valid
  bool isValidPower(double power) {
    return power == 0.3 || power == 0.6 || power == 1.0 || power == 2.0;
  }

  /// Get all available power levels
  List<double> get availablePowerLevels => [0.3, 0.6, 1.0, 2.0];

  /// Warn if trying to set high power on non-PA device
  bool shouldWarnHighPower(DeviceModel? model, double targetPower) {
    if (model == null) return targetPower > 0.3;
    return targetPower > model.power;
  }
}
