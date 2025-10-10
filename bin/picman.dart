import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:picman/picman.dart';

void printUsage() {
  stdout.writeln('Usage:');
  stdout.writeln('  dart run bin/picman.dart images --out <output.png> <img1> <img2> [img3 ...]');
  stdout.writeln('  dart run bin/picman.dart video --out <output.png> --fps <num> <video.mp4>');
  stdout.writeln('Options:');
  stdout.writeln('  --direction [auto|vertical|horizontal]');
  stdout.writeln('  --blend <int> (default 24)');
  stdout.writeln('  --search <int> (default 400)');
  stdout.writeln('  --minOverlap <int> (default 40)');
  stdout.writeln('  --scaleToMaxWidth (flag)');
  stdout.writeln('  --bg <hexRGB e.g. FFFFFF>');
  stdout.writeln('  --fps <double> (video mode)');
}

img.Color _parseBg(String hex) {
  final String h = hex.replaceAll('#', '');
  final int v = int.parse(h, radix: 16);
  final int r = (v >> 16) & 0xFF;
  final int g = (v >> 8) & 0xFF;
  final int b = v & 0xFF;
  return img.ColorRgb8(r, g, b);
}

Future<int> main(List<String> args) async {
  if (args.isEmpty) {
    printUsage();
    return 64; // usage
  }

  final String mode = args.first;
  final Map<String, String> kv = {};
  final Set<String> flags = {};
  final List<String> rest = [];

  for (int i = 1; i < args.length; i++) {
    final a = args[i];
    if (a.startsWith('--')) {
      final key = a.substring(2);
      if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
        kv[key] = args[++i];
      } else {
        flags.add(key);
      }
    } else {
      rest.add(a);
    }
  }

  final StitchDirection direction = () {
    final d = kv['direction'] ?? 'auto';
    switch (d) {
      case 'vertical':
        return StitchDirection.vertical;
      case 'horizontal':
        return StitchDirection.horizontal;
      default:
        return StitchDirection.auto;
    }
  }();

  final int blend = int.tryParse(kv['blend'] ?? '') ?? 24;
  final int search = int.tryParse(kv['search'] ?? '') ?? 400;
  final int minOverlap = int.tryParse(kv['minOverlap'] ?? '') ?? 40;
  final bool scaleToMaxWidth = flags.contains('scaleToMaxWidth');
  final img.Color? bg = kv.containsKey('bg') ? _parseBg(kv['bg']!) : null;

  final options = StitchOptions(
    direction: direction,
    blendHeight: blend,
    searchWindow: search,
    minOverlap: minOverlap,
    scaleToMaxWidth: scaleToMaxWidth,
    backgroundColor: bg,
  );

  final String? outPath = kv['out'];
  if (outPath == null) {
    stderr.writeln('Missing --out path');
    printUsage();
    return 64;
  }

  if (mode == 'images') {
    if (rest.length < 2) {
      stderr.writeln('Provide at least 2 images');
      return 64;
    }
    final images = await ImageIO.loadImages(rest);
    if (images.length < 2) {
      stderr.writeln('Failed to load 2+ images.');
      return 66;
    }
    final stitcher = VerticalStitcher(options: options);
    final result = stitcher.stitch(images);
    await ImageIO.savePng(result.image, outPath);
    stdout.writeln('Saved: $outPath');
    return 0;
  } else if (mode == 'video') {
    if (rest.length != 1) {
      stderr.writeln('Provide a single video path');
      return 64;
    }
    final double fps = double.tryParse(kv['fps'] ?? '') ?? 1.0;
    final converter = VideoToLongImage(
      options: VideoToLongImageOptions(
        fps: fps,
        stitchOptions: options,
      ),
    );
    final result = await converter.convert(rest.first);
    await ImageIO.savePng(result.image, outPath);
    stdout.writeln('Saved: $outPath');
    return 0;
  } else {
    stderr.writeln('Unknown mode: $mode');
    printUsage();
    return 64;
  }
}
