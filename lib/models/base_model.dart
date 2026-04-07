import 'dart:ui';

class DetectionResult {
  final String modelName;   // 区分是哪个模型
  final String label;
  final double confidence;
  final Rect boundingBox;
  final List<Offset>? landmarks; // 新增：用于存储手部关键点或物体特征点 [0.0-1.0]
  final Map<String, dynamic>? extra;

  DetectionResult({
    required this.modelName,
    required this.label,
    required this.confidence,
    required this.boundingBox,
    this.landmarks,
    this.extra,
  });

  Offset get center => Offset(
        boundingBox.left + boundingBox.width / 2,
        boundingBox.top + boundingBox.height / 2,
      );
}
