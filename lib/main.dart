import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'services/database_service.dart';
import 'services/ai_detector.dart';
import 'screens/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  try {
    await DatabaseService.init();
    await AIDetector.loadModel();
  } catch (e) {
    print('[main] Baslatma hatasi: $e');
  }

  runApp(const KostebekApp());
}

class KostebekApp extends StatelessWidget {
  const KostebekApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Köstebek: Çukur Dedektörü',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFE65100)),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFE65100),
          foregroundColor: Colors.white,
          centerTitle: true,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
