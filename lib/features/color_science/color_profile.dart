import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'leica_looks.dart';
import 'lut_engine.dart';

final selectedLookProvider = StateProvider<LeicaLook>((ref) => LeicaLook.classic);

final lutEngineProvider = Provider<LutEngine>((ref) => LutEngine.instance);

final lutPreloadProvider = FutureProvider<void>((ref) async {
  await LutEngine.instance.preloadAll();
});
