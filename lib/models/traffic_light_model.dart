import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;
import '../services/model_loader.dart';
import '../utils/image_utils.dart';
import 'base_model.dart';

class TrafficLightModel {
  OrtSession? _session;
  final List<String> _labels = ['red', 'yellow', 'green'];

  Future<void> load() async {
    _session = await ModelLoader.loadModel('assets/models/trafficlight.onnx');
  }

  Future<List<DetectionResult>> predict(Uint8List imageBytes) async {
    if (_session == null) return [];

    final img.Image? original = ImageUtils.decodeImage(imageBytes);
    if (original == null) return [];

    final img.Image resized = ImageUtils.resize(original, 320, 320);
    final List<double> tensor = ImageUtils.imageToCHW(resized, 320);
    final inputs = {
      'images': await OrtValue.fromList(tensor, [1, 3, 320, 320]),
    };
    final outputs = await _session!.run(inputs);
    final output = outputs['output0'];
    if (output == null) return [];

    final raw = await output.asList();
    final List<double> flat = ImageUtils.flatten(raw);
    // 假设输出形状为 [1, 6, 2100] (4坐标+1置信度+1类别)
    const int numDetections = 2100;
    const int numValues = 6;   // 需根据实际输出调整
    final List<DetectionResult> results = [];

    for (int i = 0; i < numDetections; i++) {
      final offset = i * numValues;
      final cx = flat[offset];
      final cy = flat[offset + 1];
      final w = flat[offset + 2];
      final h = flat[offset + 3];
      final objConf = flat[offset + 4];
      final classScore = flat[offset + 5];
      final confidence = objConf * classScore;
      if (confidence < 0.5) continue;

      final x1 = (cx - w / 2).clamp(0.0, 1.0);
      final y1 = (cy - h / 2).clamp(0.0, 1.0);
      final x2 = (cx + w / 2).clamp(0.0, 1.0);
      final y2 = (cy + h / 2).clamp(0.0, 1.0);
      // 根据类别分数确定标签（此处简化，需要实际多类）
      final int labelIdx = classScore > 0.5 ? 0 : 0; // 需完善
      results.add(DetectionResult(
        modelName: 'traffic_light',
        label: _labels[labelIdx],
        confidence: confidence,
        boundingBox: Rect.fromLTRB(x1, y1, x2, y2),
      ));
    }
    return results;
  }

  void dispose() {
    _session = null;
  }
}