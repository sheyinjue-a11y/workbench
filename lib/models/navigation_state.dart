// lib/models/navigation_state.dart
import 'package:flutter/foundation.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'navigation_state.freezed.dart';
part 'navigation_state.g.dart'; // 如果你需要JSON序列化/反序列化

// 用于表示从Kotlin接收到的可视化元素
// 对应 Python ProcessingResult.visualizations 列表中的每一个Dict
// 详细字段根据实际可视化需求定义，注意字段名称与Kotlin传递的Map键保持一致
@freezed
class VisualElement with _$VisualElement {
  const factory VisualElement.maskOverlay({
    required List<List<int>> points, // 多边形点坐标，[[x1,y1], [x2,y2], ...]
    required String color, // RGBA格式字符串，如 "rgba(0, 255, 0, 0.4)"
    String? effect, // 效果，如 "pulse"
    double? pulseSpeed,
  }) = _MaskOverlay;

  const factory VisualElement.polyline({
    required List<List<int>> points,
    required String color,
    int? width,
  }) = _Polyline;

  const factory VisualElement.circle({
    required List<int> center, // [x, y]
    required int radius,
    required String color,
    bool? filled,
    int? thickness,
  }) = _Circle;

  const factory VisualElement.rectangle({
    @JsonKey(name: 'top_left') required List<int> topLeft, // [x, y]
    @JsonKey(name: 'bottom_right') required List<int> bottomRight, // [x, y]
    required String color,
    bool? filled,
    int? thickness,
  }) = _Rectangle;

  const factory VisualElement.arrow({
    required List<int> start, // [x, y]
    required List<int> end, // [x, y]
    required String color,
    int? thickness,
    @JsonKey(name: 'tip_length') double? tipLength,
  }) = _Arrow;

  const factory VisualElement.dashedLine({
    required List<int> start, // [x, y]
    required List<int> end, // [x, y]
    required String color,
    int? thickness,
  }) = _DashedLine;

  const factory VisualElement.angleArc({
    required List<int> center, // [x, y]
    required int radius,
    @JsonKey(name: 'start_angle') required double startAngle, // 角度
    @JsonKey(name: 'end_angle') required double endAngle,   // 角度
    required String color,
    int? thickness,
  }) = _AngleArc;

  const factory VisualElement.textWithBg({
    required String text,
    required List<int> position, // [x, y]
    @JsonKey(name: 'font_scale') double? fontScale,
    required String color,
    @JsonKey(name: 'bg_color') String? bgColor, // RGBA格式字符串
  }) = _TextWithBg;

  const factory VisualElement.dataPanel({
    required Map<String, String> data, // 键值对数据
    required List<int> position, // [x, y]
  }) = _DataPanel;

  // 新增：表示轮廓线，对应 Python viz_elements 中的 'outline' 类型
  const factory VisualElement.outline({
    required List<List<int>> points,
    required String color,
    int? thickness,
  }) = _Outline;

  // 新增：双向箭头，对应 Python viz_elements 中的 'double_arrow' 类型
  const factory VisualElement.doubleArrow({
    required List<int> start,
    required List<int> end,
    required String color,
    int? thickness,
    @JsonKey(name: 'tip_length') double? tipLength,
  }) = _DoubleArrow;

  // 添加更多可视化类型...

  // 从Map反序列化的工厂构造函数
  factory VisualElement.fromJson(Map<String, dynamic> json) => _$VisualElementFromJson(json);
}

// 导航器当前的状态和数据
@freezed
class NavigationState with _$NavigationState {
  const factory NavigationState({
    required String currentOverallState, // 对应 NavigationMaster 的状态，如 "BLINDPATH_NAV"
    required String currentBlindPathSubState, // 对应 BlindPathNavigator 的子状态，如 "NAVIGATING"
    required String guidanceText, // 语音引导文本
    @Default([]) List<VisualElement> visualizations, // 用于UI渲染的可视化元素
    @Default({}) Map<String, dynamic> stateDetails, // 更多详细状态信息（如角度、偏移、障碍物列表、交通灯颜色）
    @Default(false) bool isBusy, // 是否正在处理中（例如：等待模型推理）
    String? errorMessage, // 错误信息
  }) = _NavigationState;

  // 从Map反序列化的工厂构造函数
  factory NavigationState.fromJson(Map<String, dynamic> json) => _$NavigationStateFromJson(json);
}
