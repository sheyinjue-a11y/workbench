import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

class DepthEstimator {
  static const int inputSize = 256;
  Interpreter? _interpreter;

  // 量化参数
  static const double inputScale = 0.00487531116232276;
  static const double inputZeroPoint = 24.0;
  static const double outputScale = 6.514298915863037;

  Future<void> load() async {
    try {
      final modelData = await rootBundle.load('assets/models/midas.tflite');
      print('📦 模型文件大小: ${modelData.lengthInBytes} bytes');
      final uint8List = modelData.buffer.asUint8List();
      _interpreter = await Interpreter.fromBuffer(uint8List);
      print('✅ MiDaS 模型加载成功');
    } catch (e) {
      print('❌ 模型加载失败: $e');
      rethrow;
    }
  }

  Future<img.Image> estimateDepth(img.Image image) async {
    if (_interpreter == null) throw Exception('模型未加载');

    // 1. 调整图像到 256x256
    final inputImage = img.copyResize(image, width: inputSize, height: inputSize);
    
    // 2. 转换为 uint8 张量 [1, 256, 256, 3]
    final inputBytes = _imageToUint8Tensor(inputImage);
    
    // 3. 输出缓冲区 [1, 256, 256, 1] uint8
    final outputBytes = Uint8List(1 * inputSize * inputSize * 1);
    final outputBuffer = outputBytes.buffer;
    
    // 4. 运行推理
    final start = DateTime.now();
    _interpreter!.run(inputBytes, outputBuffer);
    final elapsed = DateTime.now().difference(start).inMilliseconds;
    print('⏱️ 深度估计耗时: $elapsed ms');

    // 5. 将输出 uint8 转换为实际深度值
    final outputUint8 = outputBytes.buffer.asUint8List();
    final depthValues = Float32List(outputUint8.length);
    for (int i = 0; i < outputUint8.length; i++) {
      depthValues[i] = outputScale * outputUint8[i];
    }
    
    // 6. 转换为灰度图像（用于预览和障碍物检测）
    final depthImage = img.Image(width: inputSize, height: inputSize);
    
    // 获取深度范围
    double minDepth = depthValues[0];
    double maxDepth = depthValues[0];
    for (int i = 1; i < depthValues.length; i++) {
      if (depthValues[i] < minDepth) minDepth = depthValues[i];
      if (depthValues[i] > maxDepth) maxDepth = depthValues[i];
    }
    
    // 归一化到 0-255 用于显示
    if ((maxDepth - minDepth).abs() < 1e-6) maxDepth = minDepth + 1.0;
    for (int i = 0; i < depthValues.length; i++) {
      final int val = ((depthValues[i] - minDepth) / (maxDepth - minDepth) * 255).clamp(0, 255).toInt();
      final int x = i % inputSize;
      final int y = i ~/ inputSize;
      depthImage.setPixelRgba(x, y, val, val, val, 255);
    }
    
    return depthImage;
  }

  /// 将 RGB 图像转为 uint8 张量 [1, 256, 256, 3]
  Uint8List _imageToUint8Tensor(img.Image image) {
    final size = image.width * image.height;
    final bytes = Uint8List(1 * size * 3);
    int index = 0;
    for (int y = 0; y < image.height; y++) {
      for (int x = 0; x < image.width; x++) {
        final pixel = image.getPixel(x, y);
        bytes[index++] = pixel.r.toInt();
        bytes[index++] = pixel.g.toInt();
        bytes[index++] = pixel.b.toInt();
      }
    }
    return bytes;
  }

  bool checkObstacle(
    img.Image depthImage, {
    required int dangerThreshold,
    required double dangerRatio,
    int startX = 38,
    int endX = 217,
    int startY = 25,
    int endY = 128,
  }) {
    final totalPixels = (endX - startX) * (endY - startY);
    int dangerCount = 0;

    for (int y = startY; y < endY; y++) {
      for (int x = startX; x < endX; x++) {
        final pixel = depthImage.getPixel(x, y);
        final depthVal = pixel.r;
        if (depthVal > dangerThreshold) {
          dangerCount++;
        }
      }
    }

    final ratio = dangerCount / totalPixels;
    return ratio > dangerRatio;
  }

  void dispose() {
    _interpreter?.close();
  }
}