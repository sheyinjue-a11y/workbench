import 'dart:typed_data';
import 'package:image/image.dart' as img;

class ImageUtils {
  /// 将 Uint8List 解码为 img.Image
  static img.Image? decodeImage(Uint8List bytes) => img.decodeImage(bytes);

  /// 调整图像大小
  static img.Image resize(img.Image image, int width, int height) =>
      img.copyResize(image, width: width, height: height);

  /// 将 img.Image 转换为 CHW 格式的 float32 张量 (NCHW)
  static List<double> imageToCHW(img.Image image, int inputSize) {
    final List<double> tensor = List.filled(1 * 3 * inputSize * inputSize, 0.0);
    final int height = inputSize;
    final int width = inputSize;
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final pixel = image.getPixel(x, y);
        final double r = pixel.r / 255.0;
        final double g = pixel.g / 255.0;
        final double b = pixel.b / 255.0;

        final idxR = (0 * height + y) * width + x;
        final idxG = (1 * height + y) * width + x;
        final idxB = (2 * height + y) * width + x;

        tensor[idxR] = r;
        tensor[idxG] = g;
        tensor[idxB] = b;
      }
    }
    return tensor;
  }

  /// 递归展平嵌套列表
  static List<double> flatten(dynamic list) {
    final result = <double>[];
    if (list is List) {
      for (var item in list) {
        result.addAll(flatten(item));
      }
    } else if (list is num) {
      result.add(list.toDouble());
    }
    return result;
  }
}