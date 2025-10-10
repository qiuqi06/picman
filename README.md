# picman

Flutter/Dart utilities to:
- Stitch multiple screenshots by removing vertical overlaps
- Convert a video to a long image by sampling frames and stitching

## Install
Add to `pubspec.yaml`:

```yaml
dependencies:
  picman:
    path: .
```

Then run:

```bash
flutter pub get
```

## Usage

### Stitch images with overlap removal (auto direction, scaling, background)
```dart
import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:picman/picman.dart';

Future<void> main() async {
  final files = [
    File('assets/shot1.png'),
    File('assets/shot2.png'),
    File('assets/shot3.png'),
  ];
  final images = <img.Image>[];
  for (final f in files) {
    final bytes = await f.readAsBytes();
    final decoded = img.decodeImage(bytes)!;
    images.add(decoded);
  }

  final stitcher = VerticalStitcher(
    options: const StitchOptions(
      direction: StitchDirection.auto, // vertical/horizontal automatically
      searchWindow: 500,
      minOverlap: 40,
      blendHeight: 24,
      scaleToMaxWidth: true, // keep columns aligned by scaling instead of padding
    ),
  );
  final result = stitcher.stitch(images);

  final outBytes = img.encodePng(result.image);
  await File('out/stitched.png').writeAsBytes(outBytes);
}
```

### Video to long image
```dart
import 'dart:io';
import 'package:picman/picman.dart';
import 'package:image/image.dart' as img;

Future<void> main() async {
  final converter = VideoToLongImage(
    options: const VideoToLongImageOptions(
      fps: 0.5, // sample 1 frame every 2 seconds
      maxFrames: 300,
    ),
  );

  final result = await converter.convert('assets/demo.mp4');
  final bytes = img.encodePng(result.image);
  await File('out/video_long.png').writeAsBytes(bytes);
}
```

## Notes
- The overlap search uses normalized cross-correlation on a vertical band.
- You can set `backgroundColor` and then call `VerticalStitcher.trimUniformBorder` to remove outer margins.
- For iOS/Android, ensure FFmpegKit is properly integrated (the plugin does this automatically when built via Flutter).
