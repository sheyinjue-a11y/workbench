import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;

class DetectionResult {
  final String label;
  final double confidence;
  final Rect boundingBox;

  DetectionResult({
    required this.label,
    required this.confidence,
    required this.boundingBox,
  });

  Offset get center => Offset(
        boundingBox.left + boundingBox.width / 2,
        boundingBox.top + boundingBox.height / 2,
      );
}

class ModelManager {
  OrtSession? _session;
  OnnxRuntime? _ort;
  bool _isLoaded = false;

  final List<String> _labels = [
    'person', 'bicycle', 'car', 'motorcycle', 'airplane', 'bus', 'train', 'truck', 'boat',
    'traffic light', 'fire hydrant', 'stop sign', 'parking meter', 'bench', 'bird', 'cat',
    'dog', 'horse', 'sheep', 'cow', 'elephant', 'bear', 'zebra', 'giraffe', 'backpack',
    'umbrella', 'handbag', 'tie', 'suitcase', 'frisbee', 'skis', 'snowboard', 'sports ball',
  ];

  Future<void> init() async {
    if (_isLoaded) return;
    try {
      final modelPath = await _getModelPath();
      _ort = OnnxRuntime();
      _session = await _ort!.createSession(modelPath);
      _isLoaded = true;
    } catch (e) {
      _isLoaded = true;
    }
  }

  Future<String> _getModelPath() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/yolo-seg.onnx');
    if (!await file.exists()) {
      final data = await rootBundle.load('assets/models/yolo-seg.onnx');
      await file.writeAsBytes(data.buffer.asUint8List());
    }
    return file.path;
  }

  Future<List<DetectionResult>> detect(Uint8List imageBytes) async {
    if (!_isLoaded || _session == null) return [];
    try {
      img.Image? image = img.decodeImage(imageBytes);
      if (image == null) return [];
      const int inputSize = 320;
      img.Image resized = img.copyResize(image, width: inputSize, height: inputSize);
      const int channels = 3;
      const int height = inputSize;
      const int width = inputSize;
      List<double> tensorData = List.filled(1 * channels * height * width, 0.0);
      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          var pixel = resized.getPixel(x, y);
          tensorData[(0 * height + y) * width + x] = pixel.r / 255.0;
          tensorData[(1 * height + y) * width + x] = pixel.g / 255.0;
          tensorData[(2 * height + y) * width + x] = pixel.b / 255.0;
        }
      }
      final inputs = {'images': await OrtValue.fromList(tensorData, [1, channels, height, width])};
      final outputs = await _session!.run(inputs);
      final outputValue = outputs['output0'];
      if (outputValue == null) return [];
      final nested = await outputValue.asList();
      List<double> raw = _flattenToDouble(nested);
      return _parseDetections(raw);
    } catch (e) {
      return [];
    }
  }

  List<DetectionResult> _parseDetections(List<double> raw) {
    const int numDetections = 2100;
    const int numValues = 38;
    const int numClasses = 33;
    if (raw.length < numDetections * numValues) return [];
    List<DetectionResult> detections = [];
    for (int i = 0; i < numDetections; i++) {
      int offset = i * numValues;
      double cx = raw[offset];
      double cy = raw[offset + 1];
      double w = raw[offset + 2];
      double h = raw[offset + 3];
      double bestScore = 0;
      int bestClass = 0;
      for (int c = 0; c < numClasses; c++) {
        double score = raw[offset + 5 + c];
        if (score > bestScore) {
          bestScore = score;
          bestClass = c;
        }
      }
      double confidence = bestScore.clamp(0.0, 1.0);
      // 置信度阈值降低至 0.15 以支持雨伞识别
      if (confidence < 0.15) continue;
      double x1 = (cx - w / 2).clamp(0.0, 1.0);
      double y1 = (cy - h / 2).clamp(0.0, 1.0);
      double x2 = (cx + w / 2).clamp(0.0, 1.0);
      double y2 = (cy + h / 2).clamp(0.0, 1.0);
      detections.add(DetectionResult(
        label: bestClass < _labels.length ? _labels[bestClass] : 'object',
        confidence: confidence,
        boundingBox: Rect.fromLTRB(x1, y1, x2, y2),
      ));
    }
    detections.sort((a, b) => b.confidence.compareTo(a.confidence));
    List<DetectionResult> nmsResults = [];
    for (var det in detections) {
      bool keep = true;
      for (var kept in nmsResults) {
        if (_iou(det.boundingBox, kept.boundingBox) > 0.45) {
          keep = false;
          break;
        }
      }
      if (keep) nmsResults.add(det);
    }
    return nmsResults.take(5).toList();
  }

  List<double> _flattenToDouble(dynamic list) {
    List<double> result = [];
    if (list is List) {
      for (var item in list) result.addAll(_flattenToDouble(item));
    } else if (list is num) {
      result.add(list.toDouble());
    }
    return result;
  }

  double _iou(Rect a, Rect b) {
    double x1 = a.left > b.left ? a.left : b.left;
    double y1 = a.top > b.top ? a.top : b.top;
    double x2 = a.right < b.right ? a.right : b.right;
    double y2 = a.bottom < b.bottom ? a.bottom : b.bottom;
    double intersection = (x2 - x1).clamp(0.0, 1.0) * (y2 - y1).clamp(0.0, 1.0);
    double areaA = a.width * a.height;
    double areaB = b.width * b.height;
    double union = areaA + areaB - intersection;
    return union <= 0 ? 0 : intersection / union;
  }

  void dispose() {
    _session = null;
    _ort = null;
    _isLoaded = false;
  }
}
