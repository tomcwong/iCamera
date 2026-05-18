import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

class StorageService {
  StorageService._();
  static final instance = StorageService._();

  Future<bool> requestPermissions() async {
    if (Platform.isAndroid) {
      final camera = await Permission.camera.request();
      final storage = await Permission.photos.request();
      return camera.isGranted && storage.isGranted;
    } else if (Platform.isIOS) {
      final camera = await Permission.camera.request();
      final photos = await Permission.photos.request();
      return camera.isGranted && photos.isGranted;
    }
    return true;
  }

  Future<List<File>> listCapturedPhotos() async {
    final dir = await _getCaptureDir();
    if (!await dir.exists()) return [];
    return dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.jpg') || f.path.endsWith('.dng'))
        .toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
  }

  Future<Directory> _getCaptureDir() async {
    final base = await getApplicationDocumentsDirectory();
    return Directory(p.join(base.path, 'Pictures', 'iCamera'));
  }
}
