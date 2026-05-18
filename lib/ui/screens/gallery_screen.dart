import 'dart:io';
import 'package:flutter/material.dart';
import '../../core/theme/leica_colors.dart';
import '../../services/storage_service.dart';

class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  List<File> _photos = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final photos = await StorageService.instance.listCapturedPhotos();
    if (mounted) setState(() { _photos = photos; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: LeicaColors.black,
      appBar: AppBar(
        backgroundColor: LeicaColors.surface,
        title: const Text('GALLERY', style: TextStyle(letterSpacing: 3, fontSize: 13)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, size: 16),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: LeicaColors.red, strokeWidth: 1.5))
          : _photos.isEmpty
              ? const Center(
                  child: Text('No captures yet', style: TextStyle(color: LeicaColors.textSecondary)),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(2),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 2,
                    mainAxisSpacing: 2,
                  ),
                  itemCount: _photos.length,
                  itemBuilder: (ctx, i) {
                    final file = _photos[i];
                    return GestureDetector(
                      onTap: () => _openPhoto(ctx, file),
                      child: Hero(
                        tag: file.path,
                        child: file.path.endsWith('.dng')
                            ? Container(
                                color: LeicaColors.surfaceElevated,
                                child: const Center(
                                  child: Text('DNG', style: TextStyle(color: LeicaColors.textSecondary, fontSize: 12, letterSpacing: 2)),
                                ),
                              )
                            : Image.file(file, fit: BoxFit.cover),
                      ),
                    );
                  },
                ),
    );
  }

  void _openPhoto(BuildContext ctx, File file) {
    Navigator.of(ctx).push(MaterialPageRoute(
      builder: (_) => _PhotoView(file: file),
    ));
  }
}

class _PhotoView extends StatelessWidget {
  const _PhotoView({required this.file});
  final File file;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Center(
          child: Hero(
            tag: file.path,
            child: InteractiveViewer(
              child: Image.file(file),
            ),
          ),
        ),
      ),
    );
  }
}
