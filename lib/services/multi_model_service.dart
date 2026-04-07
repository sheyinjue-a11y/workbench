import 'dart:typed_data';
import 'dart:ui';
import '../models/blind_road_model.dart';
import '../models/traffic_light_model.dart';
import '../models/yolo_world_model.dart';
import '../models/hand_detection_model.dart';
import '../models/base_model.dart';

class MultiModelService {
  final BlindRoadModel _blindRoad = BlindRoadModel();
  final TrafficLightModel _trafficLight = TrafficLightModel();
  final YoloWorldModel _yoloWorld = YoloWorldModel();
  final HandDetectionModel _handDetector = HandDetectionModel();

  bool _initialized = false;

  Future<void> init() async {
    // 明确指定类型，解决 Future.wait 编译错误
    final List<Future<void>> loaders = [
      _blindRoad.load(),
      _trafficLight.load(),
      _yoloWorld.load(),
      _handDetector.load(),
    ];
    await Future.wait(loaders);
    _initialized = true;
  }

  Future<NavigationResult> analyze(Uint8List imageBytes, {
    bool enableBlindRoad = true,
    bool enableTrafficLight = true,
    bool enableObjectDetection = true,
  }) async {
    if (!_initialized) throw Exception('模型未初始化');

    final results = <String, dynamic>{};
    final List<Future<void>> futures = [];

    if (enableBlindRoad) {
      futures.add(_blindRoad.predict(imageBytes).then((r) => results['blind_road'] = r));
    }
    if (enableTrafficLight) {
      futures.add(_trafficLight.predict(imageBytes).then((r) => results['traffic_light'] = r));
    }
    if (enableObjectDetection) {
      futures.add(_yoloWorld.predict(imageBytes).then((r) => results['objects'] = r));
      futures.add(_handDetector.predict(imageBytes).then((r) => results['hands'] = r));
    }

    await Future.wait(futures);

    String? blindGuidance;
    if (results.containsKey('blind_road') && (results['blind_road'] as List).isNotEmpty) {
      final box = (results['blind_road'] as List).first.boundingBox;
      final centerX = box.left + box.width / 2;
      if (centerX < 0.3) blindGuidance = '盲道在左边';
      else if (centerX > 0.7) blindGuidance = '盲道在右边';
      else blindGuidance = '盲道在前方';
    }

    String? trafficGuidance;
    if (results.containsKey('traffic_light') && (results['traffic_light'] as List).isNotEmpty) {
      final status = (results['traffic_light'] as List).first.label;
      switch (status) {
        case 'red': trafficGuidance = '红灯，请停下'; break;
        case 'yellow': trafficGuidance = '黄灯，请注意'; break;
        case 'green': trafficGuidance = '绿灯，请通行'; break;
        default: trafficGuidance = '注意红绿灯';
      }
    }

    String? objectGuidance;
    if (enableObjectDetection) {
      final List<DetectionResult> objects = (results['objects'] as List?)?.cast<DetectionResult>() ?? [];
      final List<DetectionResult> hands = (results['hands'] as List?)?.cast<DetectionResult>() ?? [];
      objectGuidance = _processObjectInteraction(objects, hands);
    }

    return NavigationResult(
      blindGuidance: blindGuidance,
      trafficGuidance: trafficGuidance,
      objectGuidance: objectGuidance,
      detections: [
        if (results['blind_road'] != null) ...results['blind_road'],
        if (results['traffic_light'] != null) ...results['traffic_light'],
        if (results['objects'] != null) ...results['objects'],
        if (results['hands'] != null) ...results['hands'],
      ],
    );
  }

  String? _processObjectInteraction(List<DetectionResult> objects, List<DetectionResult> hands) {
    if (objects.isEmpty) return null;

    if (hands.isEmpty) {
      final topObj = objects.first;
      return '前方有${_translate(topObj.label)}';
    } else {
      final hand = hands.first;
      DetectionResult? nearest;
      double minDistance = 1000;

      for (var obj in objects) {
        final dist = (obj.center - hand.center).distance;
        if (dist < minDistance) {
          minDistance = dist;
          nearest = obj;
        }
      }

      if (nearest != null) {
        final dx = nearest.center.dx - hand.center.dx;
        final dy = nearest.center.dy - hand.center.dy;
        final dist = (nearest.center - hand.center).distance;

        if (dist < 0.08) {
          return '已对齐${_translate(nearest.label)}，可以抓取';
        }

        if (dx.abs() > 0.12) {
          return dx > 0 ? "向右移" : "向左移";
        } else if (dy.abs() > 0.12) {
          return dy > 0 ? "向下移" : "向上移";
        } else {
          return '正在接近${_translate(nearest.label)}';
        }
      }
    }
    return null;
  }

  String _translate(String label) {
    const map = {
      'person': '人',
      'bicycle': '自行车',
      'car': '汽车',
      'motorcycle': '摩托车',
      'backpack': '背包',
      'umbrella': '雨伞',
      'handbag': '手提包',
      'tie': '领带',
      'suitcase': '行李箱',
      'bottle': '瓶子',
      'cup': '杯子',
      'cell phone': '手机',
      'zebra_crossing': '斑马线',
      'blind_road': '盲道',
    };
    return map[label] ?? label;
  }

  void dispose() {
    _blindRoad.dispose();
    _trafficLight.dispose();
    _yoloWorld.dispose();
    _handDetector.dispose();
  }
}

class NavigationResult {
  final String? blindGuidance;
  final String? trafficGuidance;
  final String? objectGuidance;
  final List<DetectionResult> detections;

  NavigationResult({
    this.blindGuidance,
    this.trafficGuidance,
    this.objectGuidance,
    this.detections = const [],
  });

  String get combinedGuidance {
    final parts = <String>[];
    if (trafficGuidance != null) parts.add(trafficGuidance!);
    if (blindGuidance != null) parts.add(blindGuidance!);
    if (objectGuidance != null) parts.add(objectGuidance!);
    return parts.join('，');
  }
}
