import 'dart:typed_data';
import 'base_model.dart';

class HandDetectionModel {
  bool _isLoaded = false;

  Future<void> load() async {
    // 预留接口，目前设为已加载以保证流程跑通
    _isLoaded = true;
    print('📦 HandDetectionModel: 骨架加载完成');
  }

  Future<List<DetectionResult>> predict(Uint8List imageBytes) async {
    if (!_isLoaded) return [];
    
    // 暂时返回空，后续可以接入具体的 TFLite 手部模型
    return [];
  }

  void dispose() {
    _isLoaded = false;
  }
}
