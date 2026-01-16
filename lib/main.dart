import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import 'providers/app_state_provider.dart';
import 'screens/home_screen.dart';
import 'services/bluetooth/bluetooth_service.dart';
import 'services/bluetooth/mobile_bluetooth.dart';
import 'services/bluetooth/web_bluetooth.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize Hive for local storage
  await Hive.initFlutter();
  
  runApp(const MeshMapperApp());
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
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.green,
            brightness: Brightness.light,
          ),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.green,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        themeMode: ThemeMode.system,
        home: const HomeScreen(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}
