import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:picman/picman.dart';

void main() {
  runApp(const PicManApp());
}

class PicManApp extends StatelessWidget {
  const PicManApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PicMan Demo',
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Uint8List? _resultBytes;
  bool _busy = false;
  String? _status;
  final ImagePicker _picker = ImagePicker();

  Future<void> _pickImagesFromGallery() async {
    setState(() {
      _busy = true;
      _status = '从照片库选择图片…';
    });
    try {
      // 使用 image_picker 从照片库选择多张图片
      final List<XFile> images = await _picker.pickMultiImage(
        imageQuality: 90, // 保持较高质量
        maxWidth: 2048, // 限制最大宽度
        maxHeight: 2048, // 限制最大高度
      );

      if (images.isEmpty) {
        setState(() {
          _busy = false;
          _status = '已取消';
        });
        return;
      }

      setState(() => _status = '读取图片…');

      // 将 XFile 转换为 File 并加载图片
      final List<img.Image> loadedImages = [];
      for (final xFile in images) {
        final File file = File(xFile.path);
        final bytes = await file.readAsBytes();
        final decoded = img.decodeImage(bytes);
        if (decoded != null) {
          loadedImages.add(decoded);
        }
      }

      if (loadedImages.length < 2) {
        setState(() {
          _busy = false;
          _status = '至少选择两张图片';
        });
        return;
      }

      setState(() => _status = '拼接中…');
      final stitcher = VerticalStitcher(
        options: const StitchOptions(
          direction: StitchDirection.auto,
          searchWindow: 500,
          minOverlap: 40,
          blendHeight: 24,
          scaleToMaxWidth: true,
        ),
      );
      final result = stitcher.stitch(loadedImages);
      final trimmed = VerticalStitcher.trimUniformBorder(
        result.image,
        color: img.ColorRgb8(255, 255, 255),
        tolerance: 1,
      );
      final png = img.encodePng(trimmed);
      setState(() {
        _resultBytes = Uint8List.fromList(png);
        _busy = false;
        _status = '完成';
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _status = '失败: $e';
      });
    }
  }

  Future<void> _pickImagesAndStitch() async {
    setState(() {
      _busy = true;
      _status = '选择图片…';
    });
    try {
      // 智能选择初始目录：优先选择照片库相关目录
      String? initialDir;
      final String userHome = Platform.environment['HOME'] ??
          '/Users/${Platform.environment['USER']}';
      final List<String> photoPaths = [
        '$userHome/Pictures', // 标准图片目录
        '$userHome/Desktop', // 桌面（常用存放位置）
        '$userHome/Downloads', // 下载目录
        '$userHome/Documents', // 文档目录
        '$userHome/Pictures/Photos Library.photoslibrary', // Photos 应用库
        '$userHome/Pictures/iPhoto Library.photolibrary', // 旧版 iPhoto 库
        '$userHome/Pictures/Aperture Library.aplibrary', // Aperture 库
      ];

      for (final path in photoPaths) {
        if (Directory(path).existsSync()) {
          initialDir = path;
          break;
        }
      }

      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
        allowMultiple: true,
        withData: false,
        dialogTitle: '选择图片进行拼接（建议选择有重叠的截图）',
        initialDirectory: initialDir,
      );
      if (res == null || res.files.isEmpty) {
        setState(() {
          _busy = false;
          _status = '已取消';
        });
        return;
      }
      setState(() => _status = '读取图片…');
      final images =
          await ImageIO.loadImages(res.files.map((f) => f.path!).toList());
      if (images.length < 2) {
        setState(() {
          _busy = false;
          _status = '至少选择两张图片';
        });
        return;
      }
      setState(() => _status = '拼接中…');
      final stitcher = VerticalStitcher(
        options: const StitchOptions(
          direction: StitchDirection.auto,
          searchWindow: 500,
          minOverlap: 40,
          blendHeight: 24,
          scaleToMaxWidth: true,
        ),
      );
      final result = stitcher.stitch(images);
      final trimmed = VerticalStitcher.trimUniformBorder(
        result.image,
        color: img.ColorRgb8(255, 255, 255),
        tolerance: 1,
      );
      final png = img.encodePng(trimmed);
      setState(() {
        _resultBytes = Uint8List.fromList(png);
        _busy = false;
        _status = '完成';
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _status = '失败: $e';
      });
    }
  }

  Future<void> _pickVideoAndConvert() async {
    setState(() {
      _busy = true;
      _status = '视频功能暂时不可用（需要 FFmpeg）';
    });
    // 暂时禁用视频功能，避免 FFmpeg 依赖问题
    await Future.delayed(const Duration(seconds: 2));
    setState(() {
      _busy = false;
      _status = '请使用图片拼接功能';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('PicMan 长图拼接 Demo')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: _busy ? null : _pickImagesFromGallery,
                      icon: const Icon(Icons.photo_library),
                      label: const Text('从照片库选择'),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _pickImagesAndStitch,
                      icon: const Icon(Icons.folder_open),
                      label: const Text('从文件选择'),
                    ),
                    const SizedBox(width: 12),
                    if (_busy) const CircularProgressIndicator(),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _pickVideoAndConvert,
                      icon: const Icon(Icons.movie),
                      label: const Text('视频转长图'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child:
                    Text(_status!, style: const TextStyle(color: Colors.grey)),
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: _resultBytes == null
                ? const Center(child: Text('请选择图片或视频'))
                : InteractiveViewer(
                    minScale: 0.2,
                    maxScale: 5,
                    child: SingleChildScrollView(
                      child: Image.memory(_resultBytes!),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
