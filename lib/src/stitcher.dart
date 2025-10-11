import 'dart:math' as math;

import 'package:image/image.dart' as img;

enum StitchDirection { vertical, horizontal, auto }

class StitchOptions {
  final int searchWindow; // pixels from top of next image to search overlap
  final int minOverlap; // minimum overlap height to consider
  final int blendHeight; // height of blending region
  final bool downscaleForSearch; // if true, use half-res for NCC search
  final StitchDirection direction; // vertical/horizontal/auto
  final bool scaleToMaxWidth; // if true, scale images to max width instead of padding
  final img.Color? backgroundColor; // used when padding or blending onto canvas
  final bool removeDuplicateTop; // if true, remove duplicate content from top of second image

  const StitchOptions({
    this.searchWindow = 400,
    this.minOverlap = 40,
    this.blendHeight = 24,
    this.downscaleForSearch = true,
    this.direction = StitchDirection.auto,
    this.scaleToMaxWidth = false,
    this.backgroundColor,
    this.removeDuplicateTop = false,
  });
}

class StitchResult {
  final img.Image image;
  final List<int> offsets; // cumulative vertical offsets for each input image in final
  const StitchResult(this.image, this.offsets);
}

/// Stitches a list of images vertically, removing overlaps between consecutive images
/// using normalized cross-correlation to estimate the best vertical offset.
class VerticalStitcher {
  final StitchOptions options;
  const VerticalStitcher({this.options = const StitchOptions()});

  StitchResult stitch(List<img.Image> images) {
    if (images.isEmpty) {
      throw ArgumentError('No images provided');
    }

    if (options.direction == StitchDirection.horizontal) {
      // Rotate images -90 deg, stitch vertically, rotate back +90
      final List<img.Image> rotated = images
          .map((im) => img.copyRotate(im, angle: -90))
          .toList(growable: false);
      final StitchResult tmp = _stitchVertical(rotated);
      final img.Image rotatedBack = img.copyRotate(tmp.image, angle: 90);
      return StitchResult(rotatedBack, tmp.offsets);
    }

    if (options.direction == StitchDirection.auto) {
      // Heuristic: try small preview vertical vs horizontal NCC and pick higher score
      final double vScore = _estimateDirectionScore(images, StitchDirection.vertical);
      final double hScore = _estimateDirectionScore(images, StitchDirection.horizontal);
      if (hScore > vScore) {
        final List<img.Image> rotated = images
            .map((im) => img.copyRotate(im, angle: -90))
            .toList(growable: false);
        final StitchResult tmp = _stitchVertical(rotated);
        final img.Image rotatedBack = img.copyRotate(tmp.image, angle: 90);
        return StitchResult(rotatedBack, tmp.offsets);
      }
      // else fall through to vertical
    }

    return _stitchVertical(images);
  }

  StitchResult _stitchVertical(List<img.Image> images) {
    // Special handling for multiple images with removeDuplicateTop option
    if (options.removeDuplicateTop) {
      return _stitchMultipleImagesWithDuplicateRemoval(images);
    }

    // Normalize widths by either padding or scaling to the max width
    final int targetWidth = images.map((e) => e.width).reduce(math.max);
    final List<img.Image> normalized = images.map((im) {
      if (options.scaleToMaxWidth && im.width != targetWidth) {
        final int newH = (im.height * targetWidth / im.width).round();
        return img.copyResize(im, width: targetWidth, height: newH, interpolation: img.Interpolation.linear);
      }
      return _padToWidth(im, targetWidth);
    }).toList(growable: false);

    final List<int> yOffsets = [0];
    int currentBottom = normalized.first.height;

    for (int i = 1; i < normalized.length; i++) {
      final img.Image prev = normalized[i - 1];
      final img.Image next = normalized[i];

      final int overlap = _estimateVerticalOverlap(prev, next);
      final int offset = math.max(0, currentBottom - overlap);
      yOffsets.add(offset);
      currentBottom = offset + next.height;
    }

    final int totalHeight = currentBottom;
    final img.Image canvas = img.Image(width: targetWidth, height: totalHeight);

    // Draw first image
    img.fill(canvas, color: options.backgroundColor ?? img.ColorRgb8(255, 255, 255));
    img.compositeImage(canvas, normalized.first, dstX: 0, dstY: 0);

    // Composite subsequent images with optional blending in the overlap region
    for (int i = 1; i < normalized.length; i++) {
      final img.Image prev = normalized[i - 1];
      final img.Image next = normalized[i];
      final int dstY = yOffsets[i];
      final int prevBottom = yOffsets[i - 1] + prev.height;
      final int overlapHeight = math.max(0, prevBottom - dstY);

      if (overlapHeight > 0) {
        final int blendH = math.min(options.blendHeight, overlapHeight);
        // Copy non-overlap top part of next
        if (blendH < next.height) {
          final img.Image top = img.copyCrop(next, x: 0, y: 0, width: next.width, height: next.height - blendH);
          img.compositeImage(canvas, top, dstX: 0, dstY: dstY);
        }
        // Blend the overlapping strip
        final int nextOverlapY = next.height - blendH;
        final img.Image nextStrip = img.copyCrop(next, x: 0, y: nextOverlapY, width: next.width, height: blendH);
        final int canvasOverlapY = prevBottom - blendH;
        final img.Image canvasStrip = img.copyCrop(canvas, x: 0, y: canvasOverlapY, width: targetWidth, height: blendH);
        final img.Image blended = _linearBlendVertical(canvasStrip, nextStrip);
        img.compositeImage(canvas, blended, dstX: 0, dstY: canvasOverlapY);
      } else {
        img.compositeImage(canvas, next, dstX: 0, dstY: dstY);
      }
    }

    return StitchResult(canvas, yOffsets);
  }

  /// Special method for stitching multiple images with duplicate removal
  StitchResult _stitchMultipleImagesWithDuplicateRemoval(List<img.Image> images) {
    if (images.isEmpty) {
      throw ArgumentError('No images provided');
    }

    // Normalize widths
    final int targetWidth = images.map((e) => e.width).reduce(math.max);
    final List<img.Image> normalized = images.map((im) => _normalizeImageWidth(im, targetWidth)).toList();

    // Calculate offsets and duplicate heights for each image
    final List<int> yOffsets = [0];
    final List<int> duplicateHeights = [0]; // First image has no duplicate
    int currentBottom = normalized.first.height;

    for (int i = 1; i < normalized.length; i++) {
      final img.Image prev = normalized[i - 1];
      final img.Image next = normalized[i];

      // Find duplicate height between previous image bottom and current image top
      final int duplicateHeight = _findDuplicateTopHeight(prev, next);
      duplicateHeights.add(duplicateHeight);

      // Calculate offset: current bottom minus duplicate height
      final int offset = math.max(0, currentBottom - duplicateHeight);
      yOffsets.add(offset);
      currentBottom = offset + next.height;
    }

    // Create the result image
    final int totalHeight = currentBottom;
    final img.Image result = img.Image(width: targetWidth, height: totalHeight);
    
    // Fill background
    img.fill(result, color: options.backgroundColor ?? img.ColorRgb8(255, 255, 255));
    
    // Place first image at the top
    img.compositeImage(result, normalized.first, dstX: 0, dstY: 0);
    
    // Place subsequent images, skipping duplicate parts
    for (int i = 1; i < normalized.length; i++) {
      final img.Image current = normalized[i];
      final int duplicateHeight = duplicateHeights[i];
      final int dstY = yOffsets[i];
      
      // Crop the current image to remove duplicate top part
      final img.Image cropped = img.copyCrop(
        current, 
        x: 0, 
        y: duplicateHeight, 
        width: current.width, 
        height: current.height - duplicateHeight
      );
      
      // Place the cropped image
      img.compositeImage(result, cropped, dstX: 0, dstY: dstY);
    }

    return StitchResult(result, yOffsets);
  }

  /// Special method for stitching exactly two images with duplicate top removal
  StitchResult _stitchTwoImagesWithDuplicateRemoval(List<img.Image> images) {
    if (images.length != 2) {
      throw ArgumentError('This method only handles exactly 2 images');
    }

    final img.Image first = images[0];
    final img.Image second = images[1];

    // Normalize widths
    final int targetWidth = math.max(first.width, second.width);
    final img.Image normalizedFirst = _normalizeImageWidth(first, targetWidth);
    final img.Image normalizedSecond = _normalizeImageWidth(second, targetWidth);

    // Find the best overlap between first image bottom and second image top
    final int duplicateHeight = _findDuplicateTopHeight(normalizedFirst, normalizedSecond);
    
    // Create the result image
    final int resultHeight = normalizedFirst.height + normalizedSecond.height - duplicateHeight;
    final img.Image result = img.Image(width: targetWidth, height: resultHeight);
    
    // Fill background
    img.fill(result, color: options.backgroundColor ?? img.ColorRgb8(255, 255, 255));
    
    // Place first image at the top
    img.compositeImage(result, normalizedFirst, dstX: 0, dstY: 0);
    
    // Place second image below first, skipping the duplicate top part
    img.compositeImage(result, normalizedSecond, dstX: 0, dstY: normalizedFirst.height - duplicateHeight);
    
    return StitchResult(result, [0, normalizedFirst.height - duplicateHeight]);
  }

  /// Find the height of duplicate content at the top of second image
  int _findDuplicateTopHeight(img.Image first, img.Image second) {
    final int maxSearchHeight = math.min(
      math.min(first.height, second.height),
      options.searchWindow,
    );
    
    if (maxSearchHeight < options.minOverlap) {
      return 0;
    }

    double bestScore = double.negativeInfinity;
    int bestHeight = 0;

    // Search from minOverlap to maxSearchHeight
    for (int h = options.minOverlap; h <= maxSearchHeight; h += 2) {
      // Get bottom part of first image
      final img.Image firstBottom = img.copyCrop(
        first, 
        x: 0, 
        y: first.height - h, 
        width: first.width, 
        height: h
      );
      
      // Get top part of second image
      final img.Image secondTop = img.copyCrop(
        second, 
        x: 0, 
        y: 0, 
        width: second.width, 
        height: h
      );

      // Calculate similarity score
      final double score = _ncc(firstBottom, secondTop);
      
      if (score > bestScore) {
        bestScore = score;
        bestHeight = h;
      }
    }

    // Only remove duplicate if similarity is high enough
    if (bestScore > 0.7) { // Threshold for considering content as duplicate
      return bestHeight;
    }
    
    return 0;
  }

  /// Normalize image width by padding or scaling
  img.Image _normalizeImageWidth(img.Image src, int targetWidth) {
    if (src.width == targetWidth) return src;
    
    if (options.scaleToMaxWidth) {
      final int newH = (src.height * targetWidth / src.width).round();
      return img.copyResize(src, width: targetWidth, height: newH, interpolation: img.Interpolation.linear);
    }
    
    return _padToWidth(src, targetWidth);
  }

  img.Image _padToWidth(img.Image src, int width) {
    if (src.width == width) return src;
    final img.Image out = img.Image(width: width, height: src.height);
    img.fill(out, color: options.backgroundColor ?? img.ColorRgb8(255, 255, 255));
    img.compositeImage(out, src, dstX: (width - src.width) ~/ 2, dstY: 0);
    return out;
  }

  int _estimateVerticalOverlap(img.Image top, img.Image bottom) {
    // Use a search window from the top of `bottom` against the bottom of `top`
    final int window = math.min(options.searchWindow, bottom.height);
    final int maxOverlap = math.min(top.height, window);
    if (maxOverlap < options.minOverlap) {
      return 0;
    }

    img.Image topBand = img.copyCrop(top, x: 0, y: top.height - maxOverlap, width: top.width, height: maxOverlap);
    img.Image bottomBand = img.copyCrop(bottom, x: 0, y: 0, width: bottom.width, height: maxOverlap);

    if (options.downscaleForSearch && topBand.width > 400) {
      final int newW = 400;
      final int newH = (topBand.height * newW / topBand.width).round();
      topBand = img.copyResize(topBand, width: newW, height: newH, interpolation: img.Interpolation.linear);
      bottomBand = img.copyResize(bottomBand, width: newW, height: newH, interpolation: img.Interpolation.linear);
    }

    // Slide the overlap height and pick the best NCC score
    double bestScore = double.negativeInfinity;
    int bestOverlap = options.minOverlap;

    for (int h = options.minOverlap; h <= maxOverlap; h += 2) {
      final img.Image t = img.copyCrop(topBand, x: 0, y: topBand.height - h, width: topBand.width, height: h);
      final img.Image b = img.copyCrop(bottomBand, x: 0, y: 0, width: bottomBand.width, height: h);
      final double score = _ncc(t, b);
      if (score > bestScore) {
        bestScore = score;
        bestOverlap = h;
      }
    }

    return bestOverlap;
  }

  double _ncc(img.Image a, img.Image b) {
    // Convert to luma and compute normalized cross-correlation
    final int w = a.width;
    final int h = a.height;
    if (w != b.width || h != b.height) return double.negativeInfinity;

    double sumA = 0, sumB = 0, sumAA = 0, sumBB = 0, sumAB = 0;
    final int n = w * h;
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final img.Pixel pa = a.getPixel(x, y);
        final img.Pixel pb = b.getPixel(x, y);
        final int ra = pa.r.toInt();
        final int ga = pa.g.toInt();
        final int ba = pa.b.toInt();
        final int rb = pb.r.toInt();
        final int gb = pb.g.toInt();
        final int bb = pb.b.toInt();
        final double la = 0.299 * ra + 0.587 * ga + 0.114 * ba;
        final double lb = 0.299 * rb + 0.587 * gb + 0.114 * bb;
        sumA += la;
        sumB += lb;
        sumAA += la * la;
        sumBB += lb * lb;
        sumAB += la * lb;
      }
    }
    final double meanA = sumA / n;
    final double meanB = sumB / n;
    final double varA = sumAA - n * meanA * meanA;
    final double varB = sumBB - n * meanB * meanB;
    final double cov = sumAB - n * meanA * meanB;

    if (varA <= 1e-6 || varB <= 1e-6) return -1.0;
    return cov / math.sqrt(varA * varB);
  }

  img.Image _linearBlendVertical(img.Image a, img.Image b) {
    // Same size, blend top-to-bottom with linear ramp
    assert(a.width == b.width && a.height == b.height);
    final int w = a.width;
    final int h = a.height;
    final img.Image out = img.Image(width: w, height: h);
    for (int y = 0; y < h; y++) {
      final double t = (y + 0.5) / h; // 0..1
      for (int x = 0; x < w; x++) {
        final img.Pixel pa = a.getPixel(x, y);
        final img.Pixel pb = b.getPixel(x, y);
        final int r = ((1 - t) * pa.r + t * pb.r).round();
        final int g = ((1 - t) * pa.g + t * pb.g).round();
        final int bl = ((1 - t) * pa.b + t * pb.b).round();
        out.setPixelRgba(x, y, r, g, bl, 255);
      }
    }
    return out;
  }

  double _estimateDirectionScore(List<img.Image> images, StitchDirection dir) {
    // Use first consecutive pair preview at reduced size to approximate matchability
    if (images.length < 2) return 0;
    img.Image a = images[0];
    img.Image b = images[1];
    if (dir == StitchDirection.horizontal) {
      a = img.copyRotate(a, angle: -90);
      b = img.copyRotate(b, angle: -90);
    }
    // Prepare bands
    final int window = math.min(options.searchWindow, b.height);
    final int maxOverlap = math.min(a.height, window);
    if (maxOverlap < options.minOverlap) return 0;
    img.Image topBand = img.copyCrop(a, x: 0, y: a.height - maxOverlap, width: a.width, height: maxOverlap);
    img.Image bottomBand = img.copyCrop(b, x: 0, y: 0, width: b.width, height: maxOverlap);
    if (options.downscaleForSearch && topBand.width > 300) {
      final int newW = 300;
      final int newH = (topBand.height * newW / topBand.width).round();
      topBand = img.copyResize(topBand, width: newW, height: newH, interpolation: img.Interpolation.linear);
      bottomBand = img.copyResize(bottomBand, width: newW, height: newH, interpolation: img.Interpolation.linear);
    }
    double best = -1e9;
    for (int h = options.minOverlap; h <= maxOverlap; h += 4) {
      final img.Image t = img.copyCrop(topBand, x: 0, y: topBand.height - h, width: topBand.width, height: h);
      final img.Image bb = img.copyCrop(bottomBand, x: 0, y: 0, width: bottomBand.width, height: h);
      best = math.max(best, _ncc(t, bb));
    }
    return best;
  }

  static img.Image trimUniformBorder(img.Image src, {required img.Color color, int tolerance = 0}) {
    // Remove uniform border areas matching color within tolerance
    int top = 0, bottom = src.height - 1, left = 0, right = src.width - 1;

    bool rowMatches(int y) {
      for (int x = 0; x < src.width; x++) {
        final img.Pixel p = src.getPixel(x, y);
        if (!_within(p, color, tolerance)) return false;
      }
      return true;
    }

    bool colMatches(int x) {
      for (int y = 0; y < src.height; y++) {
        final img.Pixel p = src.getPixel(x, y);
        if (!_within(p, color, tolerance)) return false;
      }
      return true;
    }

    while (top <= bottom && rowMatches(top)) top++;
    while (bottom >= top && rowMatches(bottom)) bottom--;
    while (left <= right && colMatches(left)) left++;
    while (right >= left && colMatches(right)) right--;

    if (left > right || top > bottom) {
      return img.Image(width: 1, height: 1); // empty
    }
    return img.copyCrop(src, x: left, y: top, width: right - left + 1, height: bottom - top + 1);
  }

  static bool _within(img.Pixel p, img.Color c, int tol) {
    // Compare RGB distance within tolerance
    final int cr = c.r.toInt();
    final int cg = c.g.toInt();
    final int cb = c.b.toInt();
    return (p.r - cr).abs() <= tol && (p.g - cg).abs() <= tol && (p.b - cb).abs() <= tol;
  }
}
