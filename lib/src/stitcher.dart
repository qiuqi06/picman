import 'dart:math' as math;
import 'package:image/image.dart' as img;

enum StitchDirection { vertical, horizontal, auto }

class StitchOptions {
  final int searchWindow; // pixels from top of next image to search overlap
  final int minOverlap; // minimum overlap height to consider
  final int blendHeight; // height of blending region
  final bool downscaleForSearch; // if true, use half-res for NCC search
  final StitchDirection direction; // vertical/horizontal/auto
  final bool
      scaleToMaxWidth; // if true, scale images to max width instead of padding
  final img.Color? backgroundColor; // used when padding or blending onto canvas

  const StitchOptions({
    this.searchWindow = 1800,
    this.minOverlap = 10,
    this.blendHeight = 1,
    this.downscaleForSearch = true,
    this.direction = StitchDirection.auto,
    this.scaleToMaxWidth = false,
    this.backgroundColor,
  });
}

class StitchResult {
  final img.Image image;
  final List<int>
      offsets; // cumulative vertical offsets for each input image in final
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
      final double vScore =
          _estimateDirectionScore(images, StitchDirection.vertical);
      final double hScore =
          _estimateDirectionScore(images, StitchDirection.horizontal);
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
    // Normalize widths by either padding or scaling to the max width
    final int targetWidth = images.map((e) => e.width).reduce(math.max);
    List<img.Image> normalized = images.map((im) {
      if (options.scaleToMaxWidth && im.width != targetWidth) {
        final int newH = (im.height * targetWidth / im.width).round();
        return img.copyResize(im,
            width: targetWidth,
            height: newH,
            interpolation: img.Interpolation.linear);
      }
      return _padToWidth(im, targetWidth);
    }).toList(growable: true);

    // Detect identical top and bottom bands to deduplicate common status/footer bars.
    // Keep top common band only on the first image; keep bottom common band only on the last image.
    // We cap the detection window adaptively to a reasonable height to avoid heavy comparisons.
    final int minH = normalized.map((e) => e.height).reduce(math.min);
    final int maxCommonBandCheck =
        math.min(600, (minH * 0.2).round().clamp(80, 600));
    print('maxCommonBandCheck: $maxCommonBandCheck');
    int commonTop = _commonTopIdenticalHeight(normalized, maxCommonBandCheck);
    int commonBottom =
        _commonBottomIdenticalHeight(normalized, maxCommonBandCheck);
    // commonTop = 237;

    print('commonTop: $commonTop, commonBottom: $commonBottom');

    // Apply cropping according to the rule:
    // - First image: remove only bottom common band
    // - Last image: remove only top common band
    // - Middle images: remove both top and bottom common bands
    List<img.Image> trimmed = List<img.Image>.generate(normalized.length, (i) {
      final bool isFirst = i == 0;
      final bool isLast = i == normalized.length - 1;
      final int cutTop = isFirst ? 0 : commonTop;
      final int cutBottom = isLast ? 0 : commonBottom;
      // final int cutTop = commonTop;
      // final int cutBottom = commonBottom;
      return _cropWithBounds(normalized[i], cutTop, cutBottom);
    }, growable: true);

    // trimmed.insert(
    //     0, _cropWithBounds(normalized[0], 0, normalized[0].height - commonTop));
    // trimmed.add(_cropWithBounds(normalized[normalized.length - 1],
    //     normalized[normalized.length - 1].height - commonBottom, 0));

    List<int> yOffsets = [0];
    // yOffsets.insert(1, trimmed.first.height);

    int currentBottom = trimmed.first.height;

    // return StitchResult(
    //     _cropWithBounds(normalized[normalized.length - 1],
    //         normalized[normalized.length - 1].height - commonBottom, 0),
    //     yOffsets);

    // return StitchResult(
    //     _cropWithBounds(normalized[0], 0, normalized[0].height - commonTop),
    //     yOffsets);

    // for (int i = 2; i < trimmed.length - 1; i++) {
    for (int i = 1; i < trimmed.length; i++) {
      final img.Image prev = trimmed[i - 1];
      final img.Image next = trimmed[i];

      int overlap = _estimateVerticalOverlap(prev, next);
      // overlap -= 10;
      // int overlap = 549;
      print('Image $i: overlap=$overlap');

      // int overlap = 500;
      final int offset = math.max(0, currentBottom - overlap);
      yOffsets.add(offset);
      currentBottom = offset + next.height;
      print('Image $i: overlap=$overlap, offset=$offset');
    }

    yOffsets.add(yOffsets.last + trimmed[trimmed.length - 2].height);

    final int totalHeight = currentBottom + trimmed.last.height;
    final img.Image canvas = img.Image(width: targetWidth, height: totalHeight);

    // Draw first image
    img.fill(canvas,
        color: options.backgroundColor ?? img.ColorRgb8(255, 255, 255));
    img.compositeImage(canvas, trimmed.first, dstX: 0, dstY: 0);

    // Composite subsequent images with optional blending in the overlap region
    for (int i = 1; i < trimmed.length; i++) {
      final img.Image prev = trimmed[i - 1];
      final img.Image next = trimmed[i];
      final int dstY = yOffsets[i];
      int prevBottom = yOffsets[i - 1] + prev.height;
      prevBottom = 0; //todo
      int overlapHeight = math.max(0, prevBottom - dstY);
      overlapHeight = 0; //todo

      if (overlapHeight > 0) {
        final int blendH = math.min(options.blendHeight, overlapHeight);
        // Copy non-overlap top part of next
        if (blendH < next.height) {
          final img.Image top = img.copyCrop(next,
              x: 0, y: 0, width: next.width, height: next.height - blendH);
          img.compositeImage(canvas, top, dstX: 0, dstY: dstY);
        }
        // Blend the overlapping strip
        final int nextOverlapY = next.height - blendH;
        final img.Image nextStrip = img.copyCrop(next,
            x: 0, y: nextOverlapY, width: next.width, height: blendH);
        final int canvasOverlapY = prevBottom - blendH;
        final img.Image canvasStrip = img.copyCrop(canvas,
            x: 0, y: canvasOverlapY, width: targetWidth, height: blendH);
        final img.Image blended = _linearBlendVertical(canvasStrip, nextStrip);
        img.compositeImage(canvas, blended, dstX: 0, dstY: canvasOverlapY);
      } else {
        img.compositeImage(canvas, next, dstX: 0, dstY: dstY);
      }
    }

    return StitchResult(canvas, yOffsets);
  }

  img.Image _cropWithBounds(img.Image src, int cutTop, int cutBottom) {
    final int safeTop = cutTop.clamp(0, src.height);
    final int safeBottom = cutBottom.clamp(0, src.height - safeTop);
    final int newH = math.max(1, src.height - safeTop - safeBottom);
    return img.copyCrop(src, x: 0, y: safeTop, width: src.width, height: newH);
  }

  int _commonTopIdenticalHeight(List<img.Image> imgs, int maxCheck) {
    if (imgs.length < 2) return 0;
    final int w = imgs[0].width;
    int limit = imgs.map((e) => e.height).reduce(math.min);
    limit = math.min(limit, maxCheck);
    // Tolerance-based, pairwise comparison with side margins ignored
    int perPixelTol = 12; // RGB tolerance per channel
    double minRowMatchRatio = 0.87; // percentage of pixels that must match
    final int margin = (w * 0.08).round(); // ignore ~8% left/right edges
    // int h = 0; //qqtodo 80
    int h = 0;
    int matchedRows = 0;
    int failRows = 0;
    const int maxFailRows = 3; // allow a few noisy rows (icons/indicator)
    row_loop:
    for (; h < limit; h++) {
      // Compare row h of adjacent pairs: imgs[i-1] vs imgs[i]
      // if (h > 120) {
      //   minRowMatchRatio = 0.91;
      // }
      for (int i = 1; i < imgs.length; i++) {
        int match = 0;
        final int xStart = margin;
        final int xEnd = w - margin;
        for (int x = xStart; x < xEnd; x++) {
          final img.Pixel pA = imgs[i - 1].getPixel(x, h);
          final img.Pixel pB = imgs[i].getPixel(x, h);
          if ((pA.r - pB.r).abs() <= perPixelTol &&
              (pA.g - pB.g).abs() <= perPixelTol &&
              (pA.b - pB.b).abs() <= perPixelTol) {
            match++;
          }
        }
        final int span = (xEnd - xStart).clamp(1, w);
        if (match < (minRowMatchRatio * span).round()) {
          // this pair does not match enough on this row
          matchedRows += 0; // no-op to keep context lines balanced
          // mark as failure for this row
          // break to handle failRows accounting below
          // break out of pair loop
          // and then account fail
          // (we can't label here, so use a flag)
          // but we will just break to outer accounting
          break row_loop;
        }
      }
      // if we reach here, the row matched for all adjacent pairs
      matchedRows++;
      continue;
    }
    print('matchedRows after first pass: $matchedRows');
    // If we exited early due to a failure row, count fails and continue until maxFailRows
    // Re-run from the next row until limit or fail budget exceeded
    for (int y = matchedRows + 1; y < limit && failRows <= maxFailRows; y++) {
      bool rowOk = true;
      final int xStart = margin;
      final int xEnd = w - margin;
      final int span = (xEnd - xStart).clamp(1, w);
      for (int i = 1; i < imgs.length && rowOk; i++) {
        int match = 0;
        for (int x = xStart; x < xEnd; x++) {
          final img.Pixel pA = imgs[i - 1].getPixel(x, y);
          final img.Pixel pB = imgs[i].getPixel(x, y);
          if ((pA.r - pB.r).abs() <= perPixelTol &&
              (pA.g - pB.g).abs() <= perPixelTol &&
              (pA.b - pB.b).abs() <= perPixelTol) {
            match++;
          }
        }
        if (match < (minRowMatchRatio * span).round()) {
          rowOk = false;
        }
      }
      if (rowOk) {
        matchedRows++;
      } else {
        failRows++;
      }
    }
    return matchedRows;
  }

  int _commonBottomIdenticalHeight(List<img.Image> imgs, int maxCheck) {
    if (imgs.length < 2) return 0;
    final int w = imgs[0].width;
    int limit = imgs.map((e) => e.height).reduce(math.min);
    limit = math.min(limit, maxCheck);
    // Tolerance-based, pairwise comparison with side margins ignored
    const int perPixelTol = 18;
    const double minRowMatchRatio = 0.91;
    final int margin = (w * 0.08).round();
    int h = 0;
    int matchedRows = 0;
    int failRows = 0;
    const int maxFailRows = 3;
    row_loop:
    for (; h < limit; h++) {
      final int yRef = imgs.last.height - 1 - h;
      for (int i = 0; i < imgs.length - 1; i++) {
        final int yi = imgs[i].height - 1 - h;
        int match = 0;
        final int xStart = margin;
        final int xEnd = w - margin;
        for (int x = xStart; x < xEnd; x++) {
          final img.Pixel pA = imgs[i].getPixel(x, yi);
          final img.Pixel pB = imgs.last.getPixel(x, yRef);
          if ((pA.r - pB.r).abs() <= perPixelTol &&
              (pA.g - pB.g).abs() <= perPixelTol &&
              (pA.b - pB.b).abs() <= perPixelTol) {
            match++;
          }
        }
        final int span = (xEnd - xStart).clamp(1, w);
        if (match < (minRowMatchRatio * span).round()) {
          break row_loop;
        }
      }
      matchedRows++;
    }
    for (int k = matchedRows + 1; k < limit && failRows <= maxFailRows; k++) {
      final int yRef = imgs.last.height - 1 - k;
      bool rowOk = true;
      final int xStart = margin;
      final int xEnd = w - margin;
      final int span = (xEnd - xStart).clamp(1, w);
      for (int i = 0; i < imgs.length - 1 && rowOk; i++) {
        final int yi = imgs[i].height - 1 - k;
        int match = 0;
        for (int x = xStart; x < xEnd; x++) {
          final img.Pixel pA = imgs[i].getPixel(x, yi);
          final img.Pixel pB = imgs.last.getPixel(x, yRef);
          if ((pA.r - pB.r).abs() <= perPixelTol &&
              (pA.g - pB.g).abs() <= perPixelTol &&
              (pA.b - pB.b).abs() <= perPixelTol) {
            match++;
          }
        }
        if (match < (minRowMatchRatio * span).round()) {
          rowOk = false;
        }
      }
      if (rowOk) {
        matchedRows++;
      } else {
        failRows++;
      }
    }
    return matchedRows;
  }

  img.Image _padToWidth(img.Image src, int width) {
    if (src.width == width) return src;
    final img.Image out = img.Image(width: width, height: src.height);
    img.fill(out,
        color: options.backgroundColor ?? img.ColorRgb8(255, 255, 255));
    img.compositeImage(out, src, dstX: (width - src.width) ~/ 2, dstY: 0);
    return out;
  }

  int _estimateVerticalOverlap(img.Image top, img.Image bottom) {
    // Compute max overlap height between bottom of `top` and top of `bottom` by
    // evaluating the ENTIRE overlapped region for each candidate height h,
    // and pick the largest h whose region match ratio passes the threshold.
    final int window = math.min(options.searchWindow, bottom.height);
    final int maxCheck = math.min(top.height, window);
    print('maxCheck: $maxCheck');
    if (maxCheck < options.minOverlap) return 0;

    final int w = math.min(top.width, bottom.width);
    final int margin = (w * 0.08).round(); // ignore ~8% sides
    final int xStart = margin.clamp(0, w);
    final int xEnd = (w - margin).clamp(0, w);
    final int span = math.max(1, xEnd - xStart);

    const int perPixelTol = 12; // tolerance per RGB channel
    const double minRegionMatchRatio = 0.92; // ratio across the whole region

    int best = 0;
    // for (int h = options.minOverlap; h <= maxCheck; h++) {
    for (int h = math.min(top.height, bottom.height); h >= 1; h -= 2) {
      int match = 0;
      final int total = span * h;
      if (total <= 0) continue;
      // Compare region: top[height-h .. height-1] vs bottom[0 .. h-1]
      for (int dy = 0; dy < h; dy++) {
        final int yTop = top.height - h + dy;
        final int yBottom = dy;
        if (yTop < 0 || yTop >= top.height || yBottom >= bottom.height) {
          match = 0;
          break;
        }
        for (int x = xStart; x < xEnd; x++) {
          final img.Pixel pa = top.getPixel(x, yTop);
          final img.Pixel pb = bottom.getPixel(x, yBottom);
          if ((pa.r - pb.r).abs() <= perPixelTol &&
              (pa.g - pb.g).abs() <= perPixelTol &&
              (pa.b - pb.b).abs() <= perPixelTol) {
            match++;
          }
        }
      }
      final double ratio = match / total;
      if (ratio >= minRegionMatchRatio) {
        best = h; // keep the largest h passing the threshold
        break;
      }
    }
    return best >= options.minOverlap ? best : 0;
  }

  int _refineOverlapByTolerance(
      img.Image topBand, img.Image bottomBand, int maxCheck,
      {required int seed}) {
    // Rolling multi-row refinement with consecutive failure budget
    final int w = topBand.width;
    final int hTop = topBand.height;
    final int hBottom = bottomBand.height;
    final int limit = math.min(math.min(hTop, hBottom), maxCheck);
    final int start = math.max(options.minOverlap, math.max(0, seed - 20));
    const int perPixelTol = 16; // more tolerant
    const double minRowMatchRatio = 0.9; // lower threshold
    final int margin = (w * 0.10).round(); // ignore ~10% sides
    const int windowRows = 5; // check a small window of rows for robustness
    const int maxConsecutiveFails = 2;

    int best = seed;
    int consecutiveFails = 0;
    for (int oh = start; oh <= limit; oh++) {
      // Evaluate average match ratio over up to windowRows rows near the junction
      double sumRatios = 0.0;
      int rowsChecked = 0;
      for (int k = 0; k < windowRows; k++) {
        final int rowTop = (hTop - oh) + k;
        final int rowBottom = (oh - 1) - k;
        if (rowTop < 0 ||
            rowBottom < 0 ||
            rowTop >= hTop ||
            rowBottom >= hBottom) break;
        int match = 0;
        final int xStart = margin;
        final int xEnd = w - margin;
        for (int x = xStart; x < xEnd; x++) {
          final img.Pixel pA = topBand.getPixel(x, rowTop);
          final img.Pixel pB = bottomBand.getPixel(x, rowBottom);
          if ((pA.r - pB.r).abs() <= perPixelTol &&
              (pA.g - pB.g).abs() <= perPixelTol &&
              (pA.b - pB.b).abs() <= perPixelTol) {
            match++;
          }
        }
        final int span = (xEnd - xStart).clamp(1, w);
        sumRatios += match / span;
        rowsChecked++;
      }
      final double avgRatio =
          rowsChecked == 0 ? 0.0 : (sumRatios / rowsChecked);
      if (avgRatio >= minRowMatchRatio) {
        best = oh;
        consecutiveFails = 0;
      } else {
        consecutiveFails++;
        if (consecutiveFails > maxConsecutiveFails) break;
      }
    }
    return math.max(options.minOverlap, best);
  }

  int _seedFromSampledStrips(
      img.Image topBand, img.Image bottomBand, int maxCheck,
      {int stripH = 20, int step = 100}) {
    // Sample 20px strips from the bottom of topBand upward every `step` pixels
    // and compare with the top strip of bottomBand. If similar under tolerance,
    // return that height as a seed for growth.
    final int w = topBand.width;
    final int hTop = topBand.height;
    final int hBottom = bottomBand.height;
    final int limit = math.min(math.min(hTop, hBottom), maxCheck);
    if (stripH <= 0 || limit < stripH) return 0;

    const int perPixelTol = 18;
    const double minRowMatchRatio = 0.80;
    final int margin = (w * 0.12).round();

    int bestSeed = 0;
    for (int oh = stripH; oh <= limit; oh += step) {
      // top strip ends at bottom of topBand at height `oh`
      final int topY = hTop - oh;
      final int bottomY = 0; // head of bottomBand
      if (topY < 0 || bottomY + stripH > hBottom) break;
      final img.Image tStrip =
          img.copyCrop(topBand, x: 0, y: topY, width: w, height: stripH);
      final img.Image bStrip =
          img.copyCrop(bottomBand, x: 0, y: bottomY, width: w, height: stripH);

      // Compute average ratio across strip rows
      double sumRatios = 0.0;
      for (int y = 0; y < stripH; y++) {
        int match = 0;
        final int xStart = margin;
        final int xEnd = w - margin;
        for (int x = xStart; x < xEnd; x++) {
          final img.Pixel pa = tStrip.getPixel(x, y);
          final img.Pixel pb = bStrip.getPixel(x, y);
          if ((pa.r - pb.r).abs() <= perPixelTol &&
              (pa.g - pb.g).abs() <= perPixelTol &&
              (pa.b - pb.b).abs() <= perPixelTol) {
            match++;
          }
        }
        final int span = (xEnd - xStart).clamp(1, w);
        sumRatios += match / span;
      }
      final double avgRatio = sumRatios / stripH;
      if (avgRatio >= minRowMatchRatio) {
        bestSeed = oh;
      }
    }
    return bestSeed;
  }

  int _growOverlapFromSeed(
      img.Image topBand, img.Image bottomBand, int maxCheck,
      {int seed = 10}) {
    // Start with a small overlap seed (rows from the very bottom of topBand and top of bottomBand)
    // and grow while rows match under tolerance. This directly targets scroll overlaps.
    final int w = topBand.width;
    final int hTop = topBand.height;
    final int hBottom = bottomBand.height;
    final int limit = math.min(math.min(hTop, hBottom), maxCheck);
    int oh = seed.clamp(0, limit);

    // Parameters (slightly aggressive)
    const int perPixelTol = 18;
    const double minRowMatchRatio = 0.78;
    final int margin = (w * 0.12).round();
    const int maxConsecutiveFails = 3;

    int best = oh;
    int consecutiveFails = 0;
    while (oh < limit) {
      final int rowTop =
          hTop - oh - 1; // next row to test expanding upward in top
      final int rowBottom = oh; // next row to test expanding downward in bottom
      if (rowTop < 0 || rowBottom >= hBottom) break;
      int match = 0;
      final int xStart = margin;
      final int xEnd = w - margin;
      for (int x = xStart; x < xEnd; x++) {
        final img.Pixel pA = topBand.getPixel(x, rowTop);
        final img.Pixel pB = bottomBand.getPixel(x, rowBottom);
        if ((pA.r - pB.r).abs() <= perPixelTol &&
            (pA.g - pB.g).abs() <= perPixelTol &&
            (pA.b - pB.b).abs() <= perPixelTol) {
          match++;
        }
      }
      final int span = (xEnd - xStart).clamp(1, w);
      if (match >= (minRowMatchRatio * span).round()) {
        oh++;
        best = oh;
        consecutiveFails = 0;
      } else {
        consecutiveFails++;
        if (consecutiveFails > maxConsecutiveFails) break;
        oh++;
      }
    }
    return math.max(options.minOverlap, best);
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
    img.Image topBand = img.copyCrop(a,
        x: 0, y: a.height - maxOverlap, width: a.width, height: maxOverlap);
    img.Image bottomBand =
        img.copyCrop(b, x: 0, y: 0, width: b.width, height: maxOverlap);
    if (options.downscaleForSearch && topBand.width > 300) {
      final int newW = 300;
      final int newH = (topBand.height * newW / topBand.width).round();
      topBand = img.copyResize(topBand,
          width: newW, height: newH, interpolation: img.Interpolation.linear);
      bottomBand = img.copyResize(bottomBand,
          width: newW, height: newH, interpolation: img.Interpolation.linear);
    }
    double best = -1e9;
    for (int h = options.minOverlap; h <= maxOverlap; h += 4) {
      final img.Image t = img.copyCrop(topBand,
          x: 0, y: topBand.height - h, width: topBand.width, height: h);
      final img.Image bb = img.copyCrop(bottomBand,
          x: 0, y: 0, width: bottomBand.width, height: h);
      best = math.max(best, _ncc(t, bb));
    }
    return best;
  }

  static img.Image trimUniformBorder(img.Image src,
      {required img.Color color, int tolerance = 0}) {
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
    return img.copyCrop(src,
        x: left, y: top, width: right - left + 1, height: bottom - top + 1);
  }

  static bool _within(img.Pixel p, img.Color c, int tol) {
    // Compare RGB distance within tolerance
    final int cr = c.r.toInt();
    final int cg = c.g.toInt();
    final int cb = c.b.toInt();
    return (p.r - cr).abs() <= tol &&
        (p.g - cg).abs() <= tol &&
        (p.b - cb).abs() <= tol;
  }
}
