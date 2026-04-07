import 'dart:typed_data';
import 'base_model.dart';
import 'model_manager.dart' as mm;

class YoloWorldModel {
  final mm.ModelManager _manager = mm.ModelManager();

  Future<void> load() async {
    await _manager.init();
  }

  Future<List<DetectionResult>> predict(Uint8List imageBytes) async {
    final rawResults = await _manager.detect(imageBytes);
    
    // 转换为 base_model.dart 中定义的通用 DetectionResult
    return rawResults.map((res) => DetectionResult(
      modelName: 'yolo_world',
      label: res.label,
      confidence: res.confidence,
      boundingBox: res.boundingBox,
    )).toList();
  }

  void dispose() {
    _manager.dispose();
  }
}
