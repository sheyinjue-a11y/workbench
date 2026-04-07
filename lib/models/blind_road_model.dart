import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;
import '../services/model_loader.dart';
import '../utils/image_utils.dart';
import 'base_model.dart';

class BlindRoadModel {
  OrtSession? _session;

  // 根据 Python 配置文件：0 是斑马线，1 是盲道
  static const int zebraCrossingClass = 0;
  static const int blindRoadClass = 1;

  Future<void> load() async {
    _session = await ModelLoader.loadModel('assets/models/yolo-seg.onnx');
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
    
    const int numDetections = 2100;
    const int numValues = 38; 
    final List<DetectionResult> results = [];

    for (int i = 0; i < numDetections; i++) {
      final offset = i * numValues;
      final cx = flat[offset];
      final cy = flat[offset + 1];
      final w = flat[offset + 2];
      final h = flat[offset + 3];
      final objConf = flat[offset + 4];

      // 检查斑马线 (ID: 0)
      final zebraScore = flat[offset + 5 + zebraCrossingClass];
      final zebraConf = objConf * zebraScore;

      // 检查盲道 (ID: 1)
      final blindScore = flat[offset + 5 + blindRoadClass];
      final blindConf = objConf * blindScore;

      double finalConf = 0;
      String label = '';

      if (zebraConf > 0.45 && zebraConf > blindConf) {
        finalConf = zebraConf;
        label = 'zebra_crossing';
      } else if (blindConf > 0.45) {
        finalConf = blindConf;
        label = 'blind_road';
      }

      if (finalConf < 0.45) continue;

      final x1 = (cx - w / 2).clamp(0.0, 1.0);
      final y1 = (cy - h / 2).clamp(0.0, 1.0);
      final x2 = (cx + w / 2).clamp(0.0, 1.0);
      final y2 = (cy + h / 2).clamp(0.0, 1.0);
      
      results.add(DetectionResult(
        modelName: 'road_env',
        label: label,
        confidence: finalConf,
        boundingBox: Rect.fromLTRB(x1, y1, x2, y2),
      ));
    }
    
    // NMS 简单处理：按置信度排序取最优
    results.sort((a, b) => b.confidence.compareTo(a.confidence));
    return results.take(3).toList();
  }

  void dispose() {
    _session = null;
  }
}
