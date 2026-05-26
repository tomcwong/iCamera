import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';

/// Handles saving captured images to the device storage.
/// Files are written to a local app directory (for the in-app thumbnail) and
/// also inserted into the system gallery via PhotoManager so they appear in
/// the Photos / Files app on Android 10+ (scoped storage).
class DngWriter {
  DngWriter._();
  static final instance = DngWriter._();

  /// Save a captured XFile to local storage and the system gallery.
  /// Returns the local file path (used for the in-app thumbnail).
  Future<String> save(XFile file, {bool asRaw = false}) async {
    final dir = await _getLocalDir();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final ext = asRaw ? 'dng' : 'jpg';
    final dest = p.join(dir.path, 'icamera_$timestamp.$ext');
    await file.saveTo(dest);
    if (!asRaw) await _saveToGallery(dest);
    return dest;
  }

  /// Save processed HEIF bytes to local storage only (no gallery).
  /// Call [copyToGallery] separately after any metadata post-processing.
  Future<String> saveHeifLocal(Uint8List heifBytes) async {
    final dir = await _getLocalDir();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final dest = p.join(dir.path, 'icamera_$timestamp.heic');
    await File(dest).writeAsBytes(heifBytes);
    return dest;
  }

  /// Save processed JPEG bytes to local storage only (no gallery).
  /// Call [copyToGallery] separately after any metadata post-processing.
  Future<String> saveJpegLocal(Uint8List jpegBytes) async {
    final dir = await _getLocalDir();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final dest = p.join(dir.path, 'icamera_$timestamp.jpg');
    await File(dest).writeAsBytes(jpegBytes);
    return dest;
  }

  /// Copy a local file into the system gallery (Pictures/iCamera album).
  Future<void> copyToGallery(String filePath) async {
    await _saveToGallery(filePath);
  }

  /// Insert a JPEG file into the system gallery (Pictures/iCamera album).
  /// Uses PhotoManager which calls MediaStore on Android 10+ — no extra
  /// permission needed. Silently skips on failure so capture never crashes.
  Future<void> _saveToGallery(String filePath) async {
    try {
      await PhotoManager.editor.saveImageWithPath(
        filePath,
        title: p.basename(filePath),
        relativePath: 'Pictures/iCamera',
      );
    } catch (_) {}
  }

  /// App-private local directory for the thumbnail file reference.
  /// On Android this is internal storage — always writable, never visible
  /// to other apps, cleaned up when the app is uninstalled.
  Future<Directory> _getLocalDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'iCamera'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
}
