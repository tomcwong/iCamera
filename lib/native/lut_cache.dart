import 'dart:ffi';
import 'package:ffi/ffi.dart';
import '../features/color_science/leica_looks.dart';
import '../features/color_science/lut_engine.dart';

/// Keeps each Leica Look LUT pinned as a native Float32 array so the C++
/// apply_3d_lut function can read it directly without a copy on every frame.
class LutCache {
  LutCache._();
  static final LutCache instance = LutCache._();

  final Map<LeicaLook, Pointer<Float>> _ptrs = {};

  /// Returns a native pointer to the LUT for [look], loading it if needed.
  /// Returns null if the LUT asset is not yet available.
  Future<Pointer<Float>?> get(LeicaLook look) async {
    if (_ptrs.containsKey(look)) return _ptrs[look];

    // Load via the Dart LUT engine (parses the .cube asset)
    await LutEngine.instance.preloadLook(look);
    final dartLut = LutEngine.instance.nativeData(look);
    if (dartLut == null) return null;

    final ptr = calloc<Float>(dartLut.length);
    ptr.asTypedList(dartLut.length).setAll(0, dartLut);
    _ptrs[look] = ptr;
    return ptr;
  }

  Future<void> preloadAll() async {
    for (final look in LeicaLook.values) {
      await get(look);
    }
  }

  void dispose() {
    for (final ptr in _ptrs.values) {
      calloc.free(ptr);
    }
    _ptrs.clear();
  }
}
