// lib/services/navigation_service.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:your_project_name/models/navigation_state.dart'; // 假设文件路径
import 'dart:math' as Math;

// 状态常量 (对应 Python 的 workflow_blindpath.py 中的 STATE_*)
const String STATE_ONBOARDING = "ONBOARDING";
const String STATE_NAVIGATING = "NAVIGATING";
const String STATE_MANEUVERING_TURN = "MANEUVERING_TURN";
const String STATE_AVOIDING_OBSTACLE = "AVOIDING_OBSTACLE";
const String STATE_LOCKING_ON = "LOCKING_ON";
const String STATE_UNKNOWN = "UNKNOWN"; // Dart 侧内部兜底状态

// Onboarding 子步骤常量 (对应 Python 的 ONBOARDING_STEP_*)
const String ONBOARDING_STEP_ROTATION = "ROTATION";
const String ONBOARDING_STEP_TRANSLATION = "TRANSLATION";

// 转弯子步骤常量 (对应 Python 的 MANEUVER_STEP_*)
const String MANEUVER_STEP_1_ISSUE_COMMAND = "ISSUE_COMMAND";
const String MANEUVER_STEP_2_WAIT_FOR_SHIFT = "WAIT_FOR_SHIFT";
const String MANEUVER_STEP_3_ALIGN_ON_NEW_PATH = "ALIGN_ON_NEW_PATH";

class NavigationService extends ChangeNotifier {
  static const MethodChannel _methodChannel = MethodChannel('com.example.esp_assistant_v2/navigation_methods');
  static const EventChannel _eventChannel = EventChannel('com.example.esp_assistant_v2/navigation_events');

  // Dart 侧维护的导航状态
  NavigationState _state = const NavigationState(
    currentOverallState: 'IDLE',
    currentBlindPathSubState: STATE_UNKNOWN,
    guidanceText: '等待指令...',
  );

  NavigationState get state => _state;

  // --- Dart 侧语音播报节流与管理 (与 Kotlin 侧的节流机制协同工作) ---
  DateTime _lastAnySpeechTime = DateTime.now(); // 任何语音播报的最后时间
  static const Duration _minSpeechInterval = Duration(milliseconds: 800); // 最小语音间隔，避免重叠
  String _lastSpokenGuidance = ""; // 上次实际播报的引导文本

  // Python workflow_blindpath.py 中的配置，在 Dart 侧进行硬编码或从配置加载
  // 严格来说这些阈值在Kotlin侧计算 guidanceText 时使用，但Dart侧可以用于更精细的UI反馈或二次判断
  // 这里仅作为参考，实际计算仍在Kotlin层
  static const double NAV_ORIENTATION_THRESHOLD_DEG = 10.0; // 导航模式下的方向对齐阈值
  static const double NAV_CENTER_OFFSET_THRESHOLD_RATIO = 0.15; // 导航模式下的中心偏移阈值
  static const double OBSTACLE_NEAR_DISTANCE_Y_THRESHOLD = 0.75; // 障碍物底部Y比例超过此值视为近距离
  static const double OBSTACLE_NEAR_DISTANCE_AREA_THRESHOLD = 0.12; // 障碍物面积比例超过此值视为近距离

  NavigationService() {
    _initChannels();
  }

  void _initChannels() {
    _eventChannel.receiveBroadcastStream().listen(_onEvent, onError: _onError);
  }

  // --- 事件处理器: 接收来自 Kotlin 的状态和数据 ---
  /// 处理来自 Kotlin 的事件流。
  /// 此方法是 Dart 侧接收原生层导航处理结果的入口。
  /// Kotlin 侧会发送经过其内部状态机和图像处理（包括 `workflow_blindpath.py` 逻辑）后得到的最终结果。
  @override
  void _onEvent(dynamic event) {
    if (event is Map<dynamic, dynamic>) {
      final Map<String, dynamic> data = event.cast<String, dynamic>();

      // 【核心业务逻辑填充点 1】：解析来自 Kotlin 的状态与数据
      // 对应 Python navigation_master.py 的 `process_frame` 方法返回的 `OrchestratorResult`
      // 以及 `workflow_blindpath.py` 的 `process_frame` 返回的 `ProcessingResult`
      final String currentOverallState = data['currentOverallState'] as String? ?? _state.currentOverallState;
      final String currentBlindPathSubState = data['currentBlindPathSubState'] as String? ?? STATE_UNKNOWN;
      final String guidance = data['guidanceText'] as String? ?? "";
      final Map<String, dynamic> stateDetails = (data['stateDetails'] as Map<dynamic, dynamic>?)?.cast<String, dynamic>() ?? {};

      // 解析可视化元素列表
      final List<VisualElement> visualizations = [];
      if (data['visualizations'] is List) {
        for (var vizData in data['visualizations']) {
          try {
            // 根据 type 字段反序列化为具体的 VisualElement 类型
            // 使用 fromJson 工厂构造函数简化解析（需要运行 build_runner）
            final String? type = vizData['type'] as String?;
            if (type != null) {
              final Map<String, dynamic> typedVizData = vizData.cast<String, dynamic>();
              switch (type) {
                case 'mask_overlay':
                  visualizations.add(VisualElement.maskOverlay(
                    points: (typedVizData['points'] as List).map((p) => (p as List).cast<int>()).toList(),
                    color: typedVizData['color'] as String,
                    effect: typedVizData['effect'] as String?,
                    pulseSpeed: (typedVizData['pulseSpeed'] as num?)?.toDouble(),
                  ));
                  break;
                case 'polyline':
                  visualizations.add(VisualElement.polyline(
                    points: (typedVizData['points'] as List).map((p) => (p as List).cast<int>()).toList(),
                    color: typedVizData['color'] as String,
                    width: typedVizData['width'] as int?,
                  ));
                  break;
                case 'circle':
                  visualizations.add(VisualElement.circle(
                    center: (typedVizData['center'] as List).cast<int>(),
                    radius: typedVizData['radius'] as int,
                    color: typedVizData['color'] as String,
                    filled: typedVizData['filled'] as bool?,
                    thickness: typedVizData['thickness'] as int?,
                  ));
                  break;
                case 'rectangle':
                  visualizations.add(VisualElement.rectangle(
                    topLeft: (typedVizData['top_left'] as List).cast<int>(),
                    bottomRight: (typedVizData['bottom_right'] as List).cast<int>(),
                    color: typedVizData['color'] as String,
                    filled: typedVizData['filled'] as bool?,
                    thickness: typedVizData['thickness'] as int?,
                  ));
                  break;
                case 'arrow':
                  visualizations.add(VisualElement.arrow(
                    start: (typedVizData['start'] as List).cast<int>(),
                    end: (typedVizData['end'] as List).cast<int>(),
                    color: typedVizData['color'] as String,
                    thickness: typedVizData['thickness'] as int?,
                    tipLength: (typedVizData['tip_length'] as num?)?.toDouble(),
                  ));
                  break;
                case 'dashed_line':
                  visualizations.add(VisualElement.dashedLine(
                    start: (typedVizData['start'] as List).cast<int>(),
                    end: (typedVizData['end'] as List).cast<int>(),
                    color: typedVizData['color'] as String,
                    thickness: typedVizData['thickness'] as int?,
                  ));
                  break;
                case 'angle_arc':
                  visualizations.add(VisualElement.angleArc(
                    center: (typedVizData['center'] as List).cast<int>(),
                    radius: typedVizData['radius'] as int,
                    startAngle: (typedVizData['start_angle'] as num).toDouble(),
                    endAngle: (typedVizData['end_angle'] as num).toDouble(),
                    color: typedVizData['color'] as String,
                    thickness: typedVizData['thickness'] as int?,
                  ));
                  break;
                case 'text_with_bg':
                  visualizations.add(VisualElement.textWithBg(
                    text: typedVizData['text'] as String,
                    position: (typedVizData['position'] as List).cast<int>(),
                    fontScale: (typedVizData['font_scale'] as num?)?.toDouble(),
                    color: typedVizData['color'] as String,
                    bgColor: typedVizData['bg_color'] as String?,
                  ));
                  break;
                case 'data_panel':
                  visualizations.add(VisualElement.dataPanel(
                    data: (typedVizData['data'] as Map).cast<String, String>(),
                    position: (typedVizData['position'] as List).cast<int>(),
                  ));
                  break;
                case 'outline': // 对应 Python 的 _add_obstacle_visualization 中添加的 outline
                  visualizations.add(VisualElement.outline(
                    points: (typedVizData['points'] as List).map((p) => (p as List).cast<int>()).toList(),
                    color: typedVizData['color'] as String,
                    thickness: typedVizData['thickness'] as int?,
                  ));
                  break;
                case 'double_arrow': // 对应 Python 的 _add_navigation_info_visualization 中添加的双向箭头
                  visualizations.add(VisualElement.doubleArrow(
                    start: (typedVizData['start'] as List).cast<int>(),
                    end: (typedVizData['end'] as List).cast<int>(),
                    color: typedVizData['color'] as String,
                    thickness: typedVizData['thickness'] as int?,
                    tipLength: (typedVizData['tip_length'] as num?)?.toDouble(),
                  ));
                  break;
                default:
                  debugPrint('Unknown visualization type: $type, Data: $vizData');
              }
            }
          } catch (e) {
            debugPrint('Failed to parse VisualElement: $e, Data: $vizData');
          }
        }
      }

      // 更新 Dart 侧的 NavigationState
      _state = _state.copyWith(
        currentOverallState: currentOverallState,
        currentBlindPathSubState: currentBlindPathSubState,
        guidanceText: guidance, // 从 Kotlin 接收到的最终引导文本
        visualizations: visualizations,
        stateDetails: stateDetails, // 包含更多原始数值特征
        isBusy: false,
        errorMessage: null,
      );

      // 【核心业务逻辑填充点 2】：Dart 侧语音播报逻辑 (结合 Kotlin 提供的 guidanceText)
      // 对应 Python workflow_blindpath.py 中的 `_handleGuidanceSpeech` 方法的节流逻辑
      // 这里的 TTS 播报是 Flutter 端对 Kotlin 提供的 `guidanceText` 的响应
      _handleGuidanceSpeech(_state.guidanceText); // 播报接收到的引导文本

      // 【核心业务逻辑填充点 3】：Dart 侧对关键状态变化的响应（真机调试友好）
      // 对应 Python navigation_master.py 和 workflow_blindpath.py 中的状态流转判断
      _handleStateChangeResponses(currentOverallState, currentBlindPathSubState, stateDetails);

      notifyListeners();
    } else {
      debugPrint('Received unexpected event type: $event');
    }
  }

  void _onError(Object error) {
    debugPrint('Error from event channel: $error');
    _state = _state.copyWith(errorMessage: error.toString(), isBusy: false);
    notifyListeners();
  }

  /// 处理从 Kotlin 接收到的引导文本，进行 TTS 播报和节流。
  /// 对应 Python workflow_blindpath.py 中的语音播报管理逻辑 (`_get_voice_priority`, TTS 节流)。
  /// 确保即使 Kotlin 侧有节流，Dart 侧也有一层最终的控制，避免语音过密。
  Future<void> _handleGuidanceSpeech(String guidanceText) async {
    if (guidanceText.isEmpty) {
      return; // 空文本不播报
    }

    final now = DateTime.now();
    // 检查是否满足最小播报间隔，避免语音过密
    if (now.difference(_lastAnySpeechTime) < _minSpeechInterval) {
      // debugPrint('Speech throttled: too soon to speak "$guidanceText"');
      return;
    }

    // 避免重复播报相同的短语，除非该短语被设计为可重复 (例如 "保持直行" 可能需要多次确认)
    // Python 侧有更复杂的 `straight_continuous_mode` 和 `direction_interval` 逻辑
    // Dart 侧只做简单判断，相信 Kotlin 已经处理了重复播报的逻辑
    if (guidanceText == _lastSpokenGuidance &&
        !guidanceText.contains('直行') && // 假设直行可以重复
        !guidanceText.contains('平移') && // 假设平移可以重复
        !guidanceText.contains('转动') // 假设转动可以重复
        ) {
      return;
    }

    _lastAnySpeechTime = now;
    _lastSpokenGuidance = guidanceText;
    await speakText(guidanceText); // 调用 Kotlin TTS 接口
  }

  /// Dart 侧对关键状态变化的响应，用于真机调试或辅助性提示。
  /// 对应 Python navigation_master.py 和 workflow_blindpath.py 中的状态切换逻辑。
  /// 例如，当进入一个新状态时，除了 Kotlin 的 `guidanceText` 外，Dart 还可以有额外的行为。
  void _handleStateChangeResponses(String overallState, String blindPathSubState, Map<String, dynamic> stateDetails) {
    // 示例：当从 IDLE 切换到 BLINDPATH_NAV 时，可以有额外的调试日志或振动反馈
    if (_state.currentOverallState == 'IDLE' && overallState == 'BLINDPATH_NAV') {
      debugPrint('[Dart Response] 已从空闲模式进入盲道导航！');
      // 可以触发一个短暂的设备振动 (需要 permission)
      // HapticFeedback.lightImpact();
    }

    // 示例：对上盲道子步骤的响应
    if (overallState == 'BLINDPATH_NAV') {
      if (_state.currentBlindPathSubState != blindPathSubState) {
        debugPrint('[Dart Response] 盲道导航子状态变化： ${_state.currentBlindPathSubState} -> $blindPathSubState');
        // 对应 Python workflow_blindpath.py 的 _handle_onboarding, _handle_maneuvering_turn 状态机逻辑
        switch (blindPathSubState) {
          case STATE_ONBOARDING:
            if (_state.currentBlindPathSubState != STATE_UNKNOWN) {
              // 避免首次进入时重复播报
              // await speakText('正在进入上盲道模式'); // Kotlin 应该已经播报了更具体的指令
            }
            break;
          case STATE_NAVIGATING:
            if (_state.currentBlindPathSubState != STATE_ONBOARDING && _state.currentBlindPathSubState != STATE_UNKNOWN) {
              // await speakText('已成功进入导航模式'); // Kotlin 应该已经播报了更具体的指令
            }
            break;
          case STATE_MANEUVERING_TURN:
            // 对应 Python workflow_blindpath.py 中的 `self.current_state = STATE_MANEUVERING_TURN`
            debugPrint('[Dart Response] 检测到需要转弯！');
            // 此时 Kotlin 应该已生成 "请向左/右平移" 的 guidanceText
            break;
          case STATE_AVOIDING_OBSTACLE:
            // 对应 Python workflow_blindpath.py 中的 `self.current_state = STATE_AVOIDING_OBSTACLE`
            debugPrint('[Dart Response] 触发避障模式！');
            break;
          // ... 可以根据需要添加更多子状态的响应
        }
      }

      // 【核心业务逻辑填充点 4】：利用 stateDetails 中的具体数值进行辅助判断或 UI 调整
      // 对应 Python workflow_blindpath.py 中 `_get_pixel_domain_features` 或 `_generate_navigation_guidance` 等计算出的角度、偏移等
      final double? tangentAngleRad = stateDetails['tangent_angle_rad'] as double?;
      final double? centerOffsetXRatio = stateDetails['center_offset_ratio'] as double?;

      if (tangentAngleRad != null) {
        final double tangentAngleDeg = (tangentAngleRad * 180 / Math.pi);
        // 示例：如果偏离角度过大，可以触发一个 UI 警告动画，或者一个轻微的振动 (即使 Kotlin 已播报语音)
        if (tangentAngleDeg.abs() > NAV_ORIENTATION_THRESHOLD_DEG * 1.5) { // 略高于Kotlin的阈值，用于Dart的辅助提示
          debugPrint('[Dart Warning] 方向严重偏离！角度: ${tangentAngleDeg.toStringAsFixed(1)}°');
        }
      }
      if (centerOffsetXRatio != null) {
        // 示例：如果中心偏移过大，也可以有类似的 UI 警告
        if (centerOffsetXRatio > NAV_CENTER_OFFSET_THRESHOLD_RATIO * 1.5) {
          debugPrint('[Dart Warning] 偏离盲道中心线严重！偏移: ${centerOffsetXRatio.toStringAsFixed(2)}');
        }
      }

      // 障碍物检测的额外响应
      final List<dynamic>? obstacles = stateDetails['obstacles'] as List<dynamic>?;
      if (obstacles != null && obstacles.isNotEmpty) {
        final bool nearObstacleDetected = obstacles.any((obs) {
          final double? bottomYRatio = obs['bottom_y_ratio'] as double?;
          final double? areaRatio = obs['area_ratio'] as double?;
          return (bottomYRatio != null && bottomYRatio > OBSTACLE_NEAR_DISTANCE_Y_THRESHOLD) ||
                 (areaRatio != null && areaRatio > OBSTACLE_NEAR_DISTANCE_AREA_THRESHOLD);
        });
        if (nearObstacleDetected) {
          debugPrint('[Dart Warning] 接收到近距离障碍物警报！');
          // 可以在这里触发一个更急促的震动，作为额外的触觉反馈
          // HapticFeedback.heavyImpact();
        }
      }
    }
  }

  // --- Flutter -> Kotlin 方法调用 (工作流调度) ---

  /// 启动盲道导航模式。
  /// 对应 Python navigation_master.py 的 `start_blind_path_navigation()` 方法。
  Future<void> startBlindPathNavigation() async {
    _state = _state.copyWith(isBusy: true, errorMessage: null);
    notifyListeners();
    try {
      await _methodChannel.invokeMethod('startBlindPathNavigation');
    } on PlatformException catch (e) {
      _state = _state.copyWith(errorMessage: '启动盲道导航失败: ${e.message}', isBusy: false);
      notifyListeners();
      await speakText('启动盲道导航失败'); // TTS 播报错误
    }
  }

  /// 停止所有导航模式，回到空闲或对话模式。
  /// 对应 Python navigation_master.py 的 `stop_navigation()` 方法。
  Future<void> stopNavigation() async {
    _state = _state.copyWith(isBusy: true, errorMessage: null);
    notifyListeners();
    try {
      await _methodChannel.invokeMethod('stopNavigation');
    } on PlatformException catch (e) {
      _state = _state.copyWith(errorMessage: '停止导航失败: ${e.message}', isBusy: false);
      notifyListeners();
      await speakText('停止导航失败');
    }
  }

  /// 启动过马路模式。
  /// 对应 Python navigation_master.py 的 `start_crossing()` 方法。
  Future<void> startCrossing() async {
    _state = _state.copyWith(isBusy: true, errorMessage: null);
    notifyListeners();
    try {
      await _methodChannel.invokeMethod('startCrossing');
    } on PlatformException catch (e) {
      _state = _state.copyWith(errorMessage: '启动过马路失败: ${e.message}', isBusy: false);
      notifyListeners();
      await speakText('启动过马路失败');
    }
  }

  /// 启动红绿灯检测模式。
  /// 对应 Python navigation_master.py 的 `start_traffic_light_detection()` 方法。
  Future<void> startTrafficLightDetection() async {
    _state = _state.copyWith(isBusy: true, errorMessage: null);
    notifyListeners();
    try {
      await _methodChannel.invokeMethod('startTrafficLightDetection');
    } on PlatformException catch (e) {
      _state = _state.copyWith(errorMessage: '启动红绿灯检测失败: ${e.message}', isBusy: false);
      notifyListeners();
      await speakText('启动红绿灯检测失败');
    }
  }

  /// 启动物品查找模式。
  /// 对应 Python navigation_master.py 的 `start_item_search()` 方法。
  Future<void> startItemSearch() async {
    _state = _state.copyWith(isBusy: true, errorMessage: null);
    notifyListeners();
    try {
      await _methodChannel.invokeMethod('startItemSearch');
    } on PlatformException catch (e) {
      _state = _state.copyWith(errorMessage: '启动物品查找失败: ${e.message}', isBusy: false);
      notifyListeners();
      await speakText('启动物品查找失败');
    }
  }

  /// 停止物品查找模式。
  /// 对应 Python navigation_master.py 的 `stop_item_search()` 方法。
  Future<void> stopItemSearch({bool restoreNav = true}) async {
    _state = _state.copyWith(isBusy: true, errorMessage: null);
    notifyListeners();
    try {
      await _methodChannel.invokeMethod('stopItemSearch', {'restoreNav': restoreNav});
    } on PlatformException catch (e) {
      _state = _state.copyWith(errorMessage: '停止物品查找失败: ${e.message}', isBusy: false);
      notifyListeners();
      await speakText('停止物品查找失败');
    }
  }

  /// 发送语音命令到 Kotlin 处理。
  /// 对应 Python navigation_master.py 的 `on_voice_command()` 方法。
  Future<void> sendVoiceCommand(String command) async {
    _state = _state.copyWith(isBusy: true, errorMessage: null);
    notifyListeners();
    try {
      await _methodChannel.invokeMethod('sendVoiceCommand', {'command': command});
    } on PlatformException catch (e) {
      _state = _state.copyWith(errorMessage: '发送语音命令失败: ${e.message}', isBusy: false);
      notifyListeners();
      await speakText('发送语音命令失败');
    }
  }

  /// 强制切换到指定状态（调试或特殊场景使用）。
  /// 对应 Python navigation_master.py 的 `force_state()` 方法。
  Future<void> forceState(String newState) async {
    _state = _state.copyWith(isBusy: true, errorMessage: null);
    notifyListeners();
    try {
      await _methodChannel.invokeMethod('forceState', {'state': newState});
    } on PlatformException catch (e) {
      _state = _state.copyWith(errorMessage: '强制切换状态失败: ${e.message}', isBusy: false);
      notifyListeners();
      await speakText('强制切换状态失败');
    }
  }

  /// 请求 Kotlin 原生层使用其 TTS 服务播放一段文本。
  /// 这是 Flutter 端触发语音播报的接口。
  Future<void> speakText(String text) async {
    if (text.isEmpty) return;
    try {
      debugPrint('[TTS] Requesting Kotlin to speak: "$text"');
      await _methodChannel.invokeMethod('speakText', {'text': text});
    } on PlatformException catch (e) {
      debugPrint('Kotlin TTS 播放失败: ${e.message}');
    }
  }
}
