import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import 'models/noise_floor_session.dart';
import 'providers/app_state_provider.dart';
import 'screens/main_scaffold.dart';
import 'services/bluetooth/bluetooth_service.dart';
import 'services/bluetooth/mobile_bluetooth.dart';
import 'services/bluetooth/web_bluetooth.dart';
import 'services/background_service.dart';
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

  // Load theme preference BEFORE runApp to avoid flash of wrong theme
  final initialThemeMode = await _loadInitialThemeMode();
  debugLog('[APP] Initial theme mode: $initialThemeMode');

  // Register noise floor session adapters before opening any boxes
  // Note: MarkerRepeaterInfo (14) must be registered before PingEventMarker (12)
  // since PingEventMarker contains a list of MarkerRepeaterInfo
  if (!Hive.isAdapterRegistered(10)) {
    Hive.registerAdapter(NoiseFloorSampleAdapter());
  }
  if (!Hive.isAdapterRegistered(11)) {
    Hive.registerAdapter(PingEventTypeAdapter());
  }
  if (!Hive.isAdapterRegistered(14)) {
    Hive.registerAdapter(MarkerRepeaterInfoAdapter());
  }
  if (!Hive.isAdapterRegistered(12)) {
    Hive.registerAdapter(PingEventMarkerAdapter());
  }
  if (!Hive.isAdapterRegistered(13)) {
    Hive.registerAdapter(NoiseFloorSessionAdapter());
  }
  debugLog('[APP] Noise floor session adapters registered');

  // Request permissions on startup for mobile platforms
  if (!kIsWeb) {
    await _requestPermissions();
  }

  // Clean up any orphaned background service from a previous session
  // (Android foreground service can survive app process death)
  if (!kIsWeb) {
    await BackgroundServiceManager.cleanupOrphanedService();
  }

  runApp(MeshMapperApp(initialThemeMode: initialThemeMode));
}

/// Load theme mode from Hive before app starts to avoid flash of wrong theme
Future<String> _loadInitialThemeMode() async {
  try {
    final box = await Hive.openBox('user_preferences')
        .timeout(const Duration(seconds: 5));
    final json = box.get('preferences');
    if (json != null && json is Map) {
      final themeMode = json['themeMode'] as String?;
      if (themeMode != null) {
        return themeMode;
      }
    }
  } catch (e) {
    debugLog('[HIVE] Failed to load initial theme: $e - deleting corrupt box');
    // Delete corrupt box so AppStateProvider gets a clean start
    try {
      await Hive.deleteBoxFromDisk('user_preferences');
    } catch (_) {
      // Ignore delete errors
    }
  }
  return 'dark'; // Default to dark mode
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

// Dark theme - Tailwind Slate palette
const darkColorScheme = ColorScheme.dark(
  primary: Color(0xFF059669),       // emerald-600 (main actions)
  onPrimary: Colors.white,
  secondary: Color(0xFF0284C7),     // sky-600 (TX ping)
  onSecondary: Colors.white,
  tertiary: Color(0xFF4F46E5),      // indigo-600 (auto modes)
  onTertiary: Colors.white,
  surface: Color(0xFF1E293B),       // slate-800 (cards/panels)
  onSurface: Color(0xFFF1F5F9),     // slate-100 (primary text)
  onSurfaceVariant: Color(0xFFCBD5E1), // slate-300 (muted text, brighter for contrast)
  surfaceContainerHighest: Color(0xFF0F172A), // slate-900 (main bg)
  outline: Color(0xFF334155),       // slate-700 (borders)
  error: Color(0xFFF87171),         // red-400
  onError: Colors.white,
);

// Light theme - Tailwind Slate palette (inverted)
// Note: Using darker grays for better text contrast
const lightColorScheme = ColorScheme.light(
  primary: Color(0xFF059669),       // emerald-600
  onPrimary: Colors.white,
  secondary: Color(0xFF0284C7),     // sky-600
  onSecondary: Colors.white,
  tertiary: Color(0xFF4F46E5),      // indigo-600
  onTertiary: Colors.white,
  surface: Color(0xFFF8FAFC),       // slate-50 (cards/panels)
  onSurface: Color(0xFF0F172A),     // slate-900 (primary text - darker for contrast)
  onSurfaceVariant: Color(0xFF475569), // slate-600 (muted text - darker for readability)
  surfaceContainerHighest: Color(0xFFFFFFFF), // white (main bg)
  outline: Color(0xFFCBD5E1),       // slate-300 (borders)
  error: Color(0xFFDC2626),         // red-600
  onError: Colors.white,
);

class MeshMapperApp extends StatelessWidget {
  final String initialThemeMode;

  const MeshMapperApp({super.key, required this.initialThemeMode});

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
      child: _ThemedApp(initialThemeMode: initialThemeMode),
    );
  }
}

/// Separate widget to handle theme switching with Consumer
/// Uses initialThemeMode on first build to avoid flash of wrong theme
class _ThemedApp extends StatefulWidget {
  final String initialThemeMode;

  const _ThemedApp({required this.initialThemeMode});

  @override
  State<_ThemedApp> createState() => _ThemedAppState();
}

class _ThemedAppState extends State<_ThemedApp> {
  @override
  Widget build(BuildContext context) {
    return Consumer<AppStateProvider>(
      builder: (context, appState, child) {
        // Use initial theme mode until provider has loaded preferences from storage
        // This prevents flash from default theme to user's actual preference
        final effectiveThemeMode = appState.preferencesLoaded
            ? appState.preferences.themeMode
            : widget.initialThemeMode;

        final isDarkMode = effectiveThemeMode == 'dark';

        return MaterialApp(
          title: 'MeshMapper',
          theme: ThemeData(
            colorScheme: lightColorScheme,
            scaffoldBackgroundColor: const Color(0xFFF1F5F9), // slate-100
            appBarTheme: const AppBarTheme(
              backgroundColor: Color(0xFFF8FAFC), // slate-50
              foregroundColor: Color(0xFF0F172A), // slate-900 (darker for contrast)
            ),
            cardTheme: CardThemeData(
              color: const Color(0xFFF8FAFC), // slate-50
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: Color(0xFFCBD5E1)), // slate-300
              ),
            ),
            dividerColor: const Color(0xFFCBD5E1), // slate-300
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
          darkTheme: ThemeData(
            colorScheme: darkColorScheme,
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
          themeMode: isDarkMode ? ThemeMode.dark : ThemeMode.light,
          home: const MainScaffold(),
          debugShowCheckedModeBanner: false,
        );
      },
    );
  }
}
