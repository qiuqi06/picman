import 'dart:io';

// import 'package:ffmpeg_kit_flutter_full_gpl/ffmpeg_kit.dart';  // 暂时注释
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'stitcher.dart';

class VideoToLongImageOptions {
  final double fps; // frames per second to sample
  final int maxFrames; // safety limit
  final StitchOptions stitchOptions;

  const VideoToLongImageOptions({
    this.fps = 1.0,
    this.maxFrames = 200,
    this.stitchOptions = const StitchOptions(),
  });
}

class VideoToLongImage {
  final VideoToLongImageOptions options;
  const VideoToLongImage({this.options = const VideoToLongImageOptions()});

  /// Extract frames to a temp directory using ffmpeg, load them, and stitch.
  Future<StitchResult> convert(String inputVideoPath) async {
    // 暂时禁用视频功能，避免 FFmpeg 依赖问题
    throw UnsupportedError('视频转长图功能暂时不可用，需要 FFmpeg 支持');
    
    // 原始代码（暂时注释）
    /*
    final Directory tmpDir = await Directory.systemTemp.createTemp('picman_frames_');
    final String outPattern = p.join(tmpDir.path, 'frame_%05d.png');

    // Run FFmpeg to extract frames
    final String cmd = '-y -i "${inputVideoPath}" -vf fps=${options.fps} -vsync 0 "${outPattern}"';
    await FFmpegKit.execute(cmd);

    // Read frames
    final List<FileSystemEntity> files = tmpDir.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    final List<img.Image> frames = [];
    for (final f in files) {
      if (frames.length >= options.maxFrames) break;
      final bytes = await File(f.path).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded != null) {
        frames.add(decoded);
      }
    }

    if (frames.isEmpty) {
      throw StateError('No frames extracted from video.');
    }

    final VerticalStitcher stitcher = VerticalStitcher(options: options.stitchOptions);
    final StitchResult result = stitcher.stitch(frames);

    try {
      await tmpDir.delete(recursive: true);
    } catch (_) {}

    return result;
    */
  }
}
