import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'providers/connection_provider.dart';
import 'providers/photo_provider.dart';
import 'screens/gallery_screen.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
  ));

  final connectionProvider = ConnectionProvider();
  final photoProvider = PhotoProvider();

  await Future.wait([
    connectionProvider.load(),
    photoProvider.load(),
  ]);

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: connectionProvider),
        ChangeNotifierProvider.value(value: photoProvider),
      ],
      child: const BlockPhotoApp(),
    ),
  );
}

class BlockPhotoApp extends StatelessWidget {
  const BlockPhotoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Block 相册',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: const GalleryScreen(),
    );
  }
}
