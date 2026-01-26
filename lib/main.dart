import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import 'providers/app_state_provider.dart';
import 'screens/main_scaffold.dart';
import 'services/background_service.dart';
import 'services/bluetooth/bluetooth_service.dart';
import 'services/bluetooth/mobile_bluetooth.dart';
import 'services/bluetooth/web_bluetooth.dart';
import 'services/debug_file_logger.dart';
import 'utils/constants.dart';
import 'utils/debug_logger_io.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Enable debug file logging FIRST on mobile for dev builds
  // This must happen before DebugLogger.initialize() to capture early logs
  if (!kIsWeb && AppConstants.isDevelopmentBuild) {
    await DebugFileLogger.enable();
  }

  // Initialize debug logger (checks for ?debug=1 URL param on web)
  DebugLogger.initialize();
  debugLog('[APP] MeshMapper starting...');

  // Initialize Hive for local storage
  await Hive.initFlutter();
  debugLog('[APP] Hive initialized');

  // Request permissions on startup for mobile platforms
  if (!kIsWeb) {
    await _requestPermissions();
  }

  // Initialize background service for continuous wardriving (mobile only)
  await BackgroundServiceManager.initialize();

  runApp(const MeshMapperApp());
}

/// Request all required permissions on app startup
Future<void> _requestPermissions() async {
  debugLog('[APP] Requesting permissions...');

  if (Platform.isIOS) {
    // iOS: Use Geolocator for location (permission_handler is unreliable on iOS)
    // and trigger Core Bluetooth to prompt for Bluetooth permission
    await _requestiOSPermissions();
  } else {
    // Android: Use permission_handler
    await _requestAndroidPermissions();
  }
}

/// Request permissions on iOS
Future<void> _requestiOSPermissions() async {
  // Note: Location permission is now requested AFTER showing the prominent disclosure
  // dialog in MainScaffold (required for Google Play compliance)
  debugLog('[APP] iOS: Skipping location permission (handled after disclosure)');

  // Trigger Core Bluetooth authorization by checking adapter state
  // This will cause iOS to show the Bluetooth permission prompt if not already granted
  debugLog('[APP] iOS: Triggering Core Bluetooth authorization...');
  try {
    // Just checking the adapter state triggers the iOS Bluetooth permission prompt
    final adapterState = await fbp.FlutterBluePlus.adapterState.first;
    debugLog('[APP] iOS Bluetooth adapter state: $adapterState');

    // If Bluetooth is off or unauthorized, wait a moment for user to respond to prompt
    if (adapterState != fbp.BluetoothAdapterState.on) {
      debugLog('[APP] iOS: Waiting for Bluetooth authorization...');
      // Wait up to 3 seconds for the adapter state to become 'on'
      await fbp.FlutterBluePlus.adapterState
          .where((state) => state == fbp.BluetoothAdapterState.on)
          .first
          .timeout(const Duration(seconds: 3), onTimeout: () {
        debugLog('[APP] iOS: Bluetooth authorization timeout (user may have denied or BT is off)');
        return fbp.BluetoothAdapterState.off;
      });
    }
  } catch (e) {
    debugLog('[APP] iOS: Error checking Bluetooth: $e');
  }

  // Note: iOS doesn't need notification permission for background operation.
  // iOS uses background modes (bluetooth-central, location) instead of
  // a foreground service notification like Android.
}

/// Request permissions on Android
Future<void> _requestAndroidPermissions() async {
  // Note: Location permission is now requested AFTER showing the prominent disclosure
  // dialog in MainScaffold (required for Google Play compliance)
  final permissions = [
    Permission.bluetoothScan,
    Permission.bluetoothConnect,
    Permission.notification,
    // locationWhenInUse is requested after disclosure dialog
  ];

  final statuses = await permissions.request();

  for (final entry in statuses.entries) {
    debugLog('[APP] ${entry.key}: ${entry.value}');
  }
}

class MeshMapperApp extends StatelessWidget {
  const MeshMapperApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Create platform-appropriate Bluetooth service
    final BluetoothService bluetoothService = kIsWeb 
        ? WebBluetoothService() 
        : MobileBluetoothService();

    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => AppStateProvider(bluetoothService: bluetoothService),
        ),
      ],
      child: MaterialApp(
        title: 'MeshMapper',
        theme: ThemeData(
          colorScheme: const ColorScheme.dark(
            // Tailwind Slate palette
            primary: Color(0xFF059669),       // emerald-600 (main actions)
            onPrimary: Colors.white,
            secondary: Color(0xFF0284C7),     // sky-600 (TX ping)
            onSecondary: Colors.white,
            tertiary: Color(0xFF4F46E5),      // indigo-600 (auto modes)
            onTertiary: Colors.white,
            surface: Color(0xFF1E293B),       // slate-800 (cards/panels)
            onSurface: Color(0xFFF1F5F9),     // slate-100 (primary text)
            onSurfaceVariant: Color(0xFF94A3B8), // slate-400 (muted text)
            surfaceContainerHighest: Color(0xFF0F172A), // slate-900 (main bg)
            outline: Color(0xFF334155),       // slate-700 (borders)
            error: Color(0xFFF87171),         // red-400
            onError: Colors.white,
          ),
          scaffoldBackgroundColor: const Color(0xFF0F172A), // slate-900
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF1E293B), // slate-800
            foregroundColor: Color(0xFFF1F5F9), // slate-100
          ),
          cardTheme: CardThemeData(
            color: const Color(0xFF1E293B), // slate-800
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: Color(0xFF334155)), // slate-700
            ),
          ),
          dividerColor: const Color(0xFF334155), // slate-700
          snackBarTheme: SnackBarThemeData(
            backgroundColor: const Color(0xFF334155), // slate-700
            contentTextStyle: const TextStyle(
              color: Color(0xFFF1F5F9), // slate-100
              fontSize: 14,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            behavior: SnackBarBehavior.floating,
          ),
          useMaterial3: true,
        ),
        themeMode: ThemeMode.light, // Force our dark theme
        home: const MainScaffold(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}
