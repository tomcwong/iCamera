import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'leica_looks.dart';

/// Loads and applies a 3D LUT (.cube format) to image pixel data.
/// LUT is stored as a Float32 table of size [gridSize^3 * 3].
class LutEngine {
  LutEngine._();

  static final LutEngine instance = LutEngine._();

  final Map<LeicaLook, Float32List> _cache = {};

  int _gridSize = 33;

  Future<void> preloadLook(LeicaLook look) async {
    if (_cache.containsKey(look)) return;
    final data = await rootBundle.loadString(look.lutAssetPath);
    _cache[look] = _parseCube(data);
  }

  Future<void> preloadAll() async {
    for (final look in LeicaLook.values) {
      await preloadLook(look);
    }
  }

  /// Returns the raw Float32 LUT data for use in native memory (LutCache).
  /// Returns null if the look has not been preloaded yet.
  Float32List? nativeData(LeicaLook look) => _cache[look];

  /// Apply a look to raw RGBA pixel bytes. Returns modified bytes.
  Uint8List apply(LeicaLook look, Uint8List rgba) {
    final lut = _cache[look];
    if (lut == null) return rgba;

    final out = Uint8List.fromList(rgba);
    final n = _gridSize - 1;

    for (int i = 0; i < rgba.length; i += 4) {
      final r = rgba[i] / 255.0;
      final g = rgba[i + 1] / 255.0;
      final b = rgba[i + 2] / 255.0;

      // Trilinear interpolation
      final ri = (r * n).clamp(0, n - 1).toInt();
      final gi = (g * n).clamp(0, n - 1).toInt();
      final bi = (b * n).clamp(0, n - 1).toInt();
      final rf = r * n - ri;
      final gf = g * n - gi;
      final bf = b * n - bi;

      final gs = _gridSize;
      int idx(int rr, int gg, int bb) => (rr + gg * gs + bb * gs * gs) * 3;

      double lerp(double a, double b, double t) => a + (b - a) * t;

      final c000 = idx(ri, gi, bi);
      final c100 = idx(ri + 1, gi, bi);
      final c010 = idx(ri, gi + 1, bi);
      final c110 = idx(ri + 1, gi + 1, bi);
      final c001 = idx(ri, gi, bi + 1);
      final c101 = idx(ri + 1, gi, bi + 1);
      final c011 = idx(ri, gi + 1, bi + 1);
      final c111 = idx(ri + 1, gi + 1, bi + 1);

      for (int ch = 0; ch < 3; ch++) {
        final v = lerp(
          lerp(lerp(lut[c000 + ch], lut[c100 + ch], rf), lerp(lut[c010 + ch], lut[c110 + ch], rf), gf),
          lerp(lerp(lut[c001 + ch], lut[c101 + ch], rf), lerp(lut[c011 + ch], lut[c111 + ch], rf), gf),
          bf,
        );
        out[i + ch] = (v * 255).round().clamp(0, 255);
      }
    }
    return out;
  }

  Float32List _parseCube(String content) {
    final values = <double>[];
    int? gridSize;

    for (final rawLine in content.split('\n')) {
      final line = rawLine.trim();
      if (line.startsWith('#') || line.isEmpty) continue;
      if (line.startsWith('LUT_3D_SIZE')) {
        gridSize = int.parse(line.split(RegExp(r'\s+')).last);
        _gridSize = gridSize;
        continue;
      }
      if (line.startsWith('TITLE') || line.startsWith('DOMAIN')) continue;

      final parts = line.split(RegExp(r'\s+'));
      if (parts.length == 3) {
        values.add(double.parse(parts[0]));
        values.add(double.parse(parts[1]));
        values.add(double.parse(parts[2]));
      }
    }

    return Float32List.fromList(values);
  }
}
