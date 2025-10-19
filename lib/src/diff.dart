// import 'package:image/image.dart';
// import 'dart:math' as math;

// /// 对比两张图片指定区域的相似度 MSE
// double compareImageRegions(Image img1, Image img2, Rect region) {
//   // 裁剪出相同区域
//   Image subImg1 = copyCrop(img1, region.left, region.top, region.width, region.height);
//   Image subImg2 = copyCrop(img2, region.left, region.top, region.width, region.height);
  
//   // 计算均方误差（MSE）
//   double mse = 0;
//   for (int y = 0; y < region.height; y++) {
//     for (int x = 0; x < region.width; x++) {
//       int pixel1 = subImg1.getPixel(x, y);
//       int pixel2 = subImg2.getPixel(x, y);
      
//       // 提取RGB分量（忽略Alpha通道）
//       int r1 = getRed(pixel1), g1 = getGreen(pixel1), b1 = getBlue(pixel1);
//       int r2 = getRed(pixel2), g2 = getGreen(pixel2), b2 = getBlue(pixel2);
      
//       // 计算平方差并累加
//       mse += math.pow(r1 - r2, 2) + 
//              math.pow(g1 - g2, 2) + 
//              math.pow(b1 - b2, 2);
//     }
//   }
  
//   // 归一化MSE到[0,1]范围（值越小越相似）
//   return mse / (region.width * region.height * 3 * 255 * 255);
// }

// /// 辅助类：定义矩形区域
// class Rect {
//   final int left, top, width, height;
//   Rect(this.left, this.top, this.width, this.height);
// }

// /// 示例用法
// void main() {
//   // 加载两张图片（需替换为实际路径）
//   final img1 = decodeImage(File('path/to/img1.jpg').readAsBytesSync())!;
//   final img2 = decodeImage(File('path/to/img2.jpg').readAsBytesSync())!;
  
//   // 定义对比区域（示例：左上角100x100区域）
//   final region = Rect(50, 50, 100, 100);
  
//   // 计算相似度
//   double similarity = 1 - compareImageRegions(img1, img2, region);
//   print('区域相似度：${(similarity * 100).toStringAsFixed(2)}%');
// }


// //SSIm
// double computeSSIM(Image img1, Image img2, Rect region) {
//   // 计算两个区域的均值、方差、协方差
//   double mu1 = calculateMean(img1, region);
//   double mu2 = calculateMean(img2, region);
//   double sigma1 = calculateVariance(img1, region, mu1);
//   double sigma2 = calculateVariance(img2, region, mu2);
//   double sigma12 = calculateCovariance(img1, img2, region, mu1, mu2);
  
//   // SSIM公式
//   const C1 = 6.5025, C2 = 58.5225;
//   double ssim = (2 * mu1 * mu2 + C1) * (2 * sigma12 + C2) / 
//                 ((mu1*mu1 + mu2*mu2 + C1) * (sigma1 + sigma2 + C2));
//   return ssim;
// }

// //生成差异热力图，用颜色标识差异程度 可选
// Image generateDiffHeatmap(Image img1, Image img2, Rect region) {
//   final diff = createDiffImage(img1, img2, region); // 计算像素差绝对值
//   final heatmap = createImage(region.width, region.height);
  
//   for (int y = 0; y < region.height; y++) {
//     for (int x = 0; x < region.width; x++) {
//       int diffValue = diff.getPixel(x, y);
//       // 将差异值映射到红色系（0-255）
//       int intensity = getRed(diffValue);
//       heatmap.setPixel(x, y, getColor(intensity, 0, 0));
//     }
//   }
//   return heatmap;
// }