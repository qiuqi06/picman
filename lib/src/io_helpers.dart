import 'dart:io';

import 'package:image/image.dart' as img;

class ImageIO {
  static Future<List<img.Image>> loadImages(List<String> paths) async {
    final List<img.Image> out = [];
    for (final p in paths) {
      final bytes = await File(p).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded != null) out.add(decoded);
    }
    return out;
  }

  static Future<void> savePng(img.Image image, String path) async {
    final bytes = img.encodePng(image);
    await File(path).create(recursive: true);
    await File(path).writeAsBytes(bytes);
  }
}
