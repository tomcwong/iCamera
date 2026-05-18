import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme/app_theme.dart';
import 'ui/screens/camera_screen.dart';

class ICameraApp extends ConsumerWidget {
  const ICameraApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'iCamera',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: const CameraScreen(),
    );
  }
}
