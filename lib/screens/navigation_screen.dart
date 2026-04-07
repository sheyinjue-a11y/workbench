import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:image/image.dart' as img;
import '../services/video_service.dart';
import '../services/multi_model_service.dart';
import '../services/tts_service.dart';
import '../services/depth_estimator.dart';
import '../models/base_model.dart';

// 定义互斥的工作流枚举
enum AppWorkflow { 
  obstacle, // 深度避障
  seeking,  // 物体识别与寻找 (包含手部)
  road,     // 道路导航 (斑马线/红绿灯/盲道)
  cloud     // 云端描述
}

class NavigationScreen extends StatefulWidget {
  final String espIP;
  const NavigationScreen({Key? key, required this.espIP}) : super(key: key);

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> {
  late VideoService _video;
  late MultiModelService _model;
  late TTSService _tts;
  late DepthEstimator _depthEstimator;

  // 使用 ValueNotifier 解决画面闪烁，只局部刷新图像
  final ValueNotifier<Uint8List?> _frameNotifier = ValueNotifier<Uint8List?>(null);
  
  bool _isStreaming = false;
  bool _isLoading = true;
  int _displayFps = 0;
  int _frameCount = 0;
  DateTime? _lastFpsUpdate;

  // 当前激活的工作流，默认为寻物模式
  AppWorkflow _activeWorkflow = AppWorkflow.seeking;

  bool _isAnalyzing = false;
  String _lastGuidance = '';
  String _speechLog = '等待指令...'; // 语音日志
  DateTime? _lastGuidanceTime;
  int _frameCounter = 0;
  final int _inferenceInterval = 3; // 高频推理以保证灵敏度

  List<DetectionResult> _detections = []; 

  img.Image? _depthPreview;
  bool _isDepthAnalyzing = false;
  final AudioPlayer _audioPlayer = AudioPlayer();
  String _warningMessage = '';  

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _video = VideoService(espIP: widget.espIP);
    _model = MultiModelService();
    _tts = TTSService();
    _depthEstimator = DepthEstimator();

    _video.frameStream.listen(_onFrameReceived, onError: (err) {
      print('❌ 视频帧错误: $err');
    });

    await _tts.init();
    await _model.init();
    await _depthEstimator.load();
    
    _video.start();
    setState(() {
      _isStreaming = true;
    });
    _speakAndLog("系统已就绪，当前为寻物模式");
  }

  // 辅助方法：更新日志并立即播放语音
  Future<void> _speakAndLog(String text) async {
    if (!mounted) return;
    setState(() {
      _speechLog = text;
    });
    await _tts.speak(text);
  }

  void _onFrameReceived(Uint8List frame) {
    _frameNotifier.value = frame;
    if (_isLoading) setState(() => _isLoading = false);

    _frameCount++;
    final now = DateTime.now();
    if (_lastFpsUpdate == null) {
      _lastFpsUpdate = now;
    } else if (now.difference(_lastFpsUpdate!).inMilliseconds >= 1000) {
      setState(() {
        _displayFps = _frameCount;
        _frameCount = 0;
      });
      _lastFpsUpdate = now;
    }

    _frameCounter++;
    if (_frameCounter >= _inferenceInterval) {
      _frameCounter = 0;
      // 根据工作流互斥执行对应的分析任务
      if (_activeWorkflow == AppWorkflow.seeking || _activeWorkflow == AppWorkflow.road) {
        _analyzeFrame(frame);
      } else if (_activeWorkflow == AppWorkflow.obstacle) {
        _analyzeDepth(frame);
      }
    }
  }

  Future<void> _analyzeFrame(Uint8List frame) async {
    if (_isAnalyzing) return;
    _isAnalyzing = true;
    try {
      final result = await _model.analyze(frame, 
        enableBlindRoad: _activeWorkflow == AppWorkflow.road,
        enableTrafficLight: _activeWorkflow == AppWorkflow.road,
        enableObjectDetection: _activeWorkflow == AppWorkflow.seeking,
      );
      
      setState(() {
        _detections = result.detections;
      });

      final guidance = result.combinedGuidance;
      if (guidance.isNotEmpty) {
        final now = DateTime.now();
        // 抓取指令优先级最高
        bool isUrgent = guidance.contains('抓取') || guidance.contains('避让');
        int cooldown = isUrgent ? 1000 : 2000;

        if (_lastGuidanceTime == null || 
            now.difference(_lastGuidanceTime!).inMilliseconds > cooldown) {
          
          if (guidance != _lastGuidance || isUrgent) {
            _lastGuidance = guidance;
            _lastGuidanceTime = now;
            await _speakAndLog(guidance);
          }
        }
      }
    } catch (e) {
      print('推理错误: $e');
    } finally {
      _isAnalyzing = false;
    }
  }

  Future<void> _analyzeDepth(Uint8List frame) async {
    if (_isDepthAnalyzing) return;
    _isDepthAnalyzing = true;
    try {
      final img.Image? original = img.decodeImage(frame);
      if (original == null) return;
      final depthImage = await _depthEstimator.estimateDepth(original);
      setState(() {
        _depthPreview = img.copyResize(depthImage, width: 100, height: 100);
      });
      final obstacle = _depthEstimator.checkObstacle(depthImage, dangerThreshold: 200, dangerRatio: 0.15);
      if (obstacle) {
        _triggerAlarm();
      } else if (_warningMessage.isNotEmpty) {
        setState(() => _warningMessage = '');
      }
    } catch (e) {
      print('深度分析错误: $e');
    } finally {
      _isDepthAnalyzing = false;
    }
  }

  void _triggerAlarm() {
    if (_warningMessage.isNotEmpty) return;
    setState(() { _warningMessage = '⚠️ 障碍物！'; });
    _speakAndLog("前方有障碍，请注意避让");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text('智能感知助手', style: TextStyle(fontSize: 16)),
        backgroundColor: Colors.black87,
        actions: [
          Center(child: Text('${_displayFps} FPS ', style: TextStyle(color: Colors.greenAccent, fontSize: 12))),
          IconButton(
            icon: Icon(_isStreaming ? Icons.stop : Icons.play_arrow),
            onPressed: () {
              if (_isStreaming) _video.stop(); else _video.start();
              setState(() => _isStreaming = !_isStreaming);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // 顶部工作流单选栏
          _buildWorkflowSelector(),
          
          Expanded(
            child: Stack(
              children: [
                // 视频渲染层
                Center(
                  child: AspectRatio(
                    aspectRatio: 1.0,
                    child: ValueListenableBuilder<Uint8List?>(
                      valueListenable: _frameNotifier,
                      builder: (context, frame, child) {
                        return Stack(
                          children: [
                            if (frame != null) Image.memory(frame, fit: BoxFit.contain, gaplessPlayback: true),
                            // 仅在非避障模式下显示识别框
                            if (_activeWorkflow != AppWorkflow.obstacle)
                              CustomPaint(
                                painter: DetectionPainter(detections: _detections),
                                child: Container(),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ),

                // 语音日志条
                Positioned(
                  top: 10, left: 10, right: 10,
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black54, 
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.blueAccent.withOpacity(0.5))
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.record_voice_over, color: Colors.blueAccent, size: 18),
                        SizedBox(width: 8),
                        Expanded(child: Text(_speechLog, style: TextStyle(color: Colors.white, fontSize: 13))),
                      ],
                    ),
                  ),
                ),

                // 障碍物大警告
                if (_warningMessage.isNotEmpty)
                  Center(child: Container(padding: EdgeInsets.all(20), decoration: BoxDecoration(color: Colors.red.withOpacity(0.8), borderRadius: BorderRadius.circular(10)),
                    child: Text(_warningMessage, style: TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.bold)))),

                // 深度预览 (右下角)
                if (_activeWorkflow == AppWorkflow.obstacle && _depthPreview != null)
                  Positioned(bottom: 10, right: 10, child: Container(width: 100, height: 100, decoration: BoxDecoration(border: Border.all(color: Colors.redAccent, width: 2)),
                    child: Image.memory(Uint8List.fromList(img.encodePng(_depthPreview!)), fit: BoxFit.cover))),
              ],
            ),
          ),

          // 底部指令显示
          _buildGuidancePanel(),
        ],
      ),
    );
  }

  Widget _buildWorkflowSelector() {
    return Container(
      color: Colors.black87,
      padding: EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _workflowChip('避障', AppWorkflow.obstacle),
          _workflowChip('寻物', AppWorkflow.seeking),
          _workflowChip('路导', AppWorkflow.road),
          _workflowChip('描述', AppWorkflow.cloud),
        ],
      ),
    );
  }

  Widget _workflowChip(String label, AppWorkflow workflow) {
    bool selected = _activeWorkflow == workflow;
    return ChoiceChip(
      label: Text(label, style: TextStyle(fontSize: 12, color: selected ? Colors.black : Colors.white)),
      selected: selected,
      onSelected: (val) {
        if (val) {
          setState(() {
            _activeWorkflow = workflow;
            _detections = [];
            _lastGuidance = '';
          });
          _speakAndLog("切换到$label模式");
        }
      },
      selectedColor: Colors.greenAccent,
      backgroundColor: Colors.grey[900],
    );
  }

  Widget _buildGuidancePanel() {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(color: Colors.grey[900], borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      child: Column(
        children: [
          Text('实时引导指令', style: TextStyle(color: Colors.white38, fontSize: 12, letterSpacing: 2)),
          SizedBox(height: 10),
          Text(_lastGuidance.isEmpty ? '寻找目标中...' : _lastGuidance, 
            style: TextStyle(color: Colors.greenAccent, fontSize: 24, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _video.dispose();
    _model.dispose();
    _tts.dispose();
    _depthEstimator.dispose();
    _frameNotifier.dispose();
    super.dispose();
  }
}

class DetectionPainter extends CustomPainter {
  final List<DetectionResult> detections;
  DetectionPainter({required this.detections});

  @override
  void paint(Canvas canvas, Size size) {
    final boxPaint = Paint()..style = PaintingStyle.stroke..strokeWidth = 3.0;
    final dotPaint = Paint()..style = PaintingStyle.fill..color = Colors.cyanAccent;
    final linePaint = Paint()..color = Colors.white54..strokeWidth = 1.5..style = PaintingStyle.stroke;

    for (var det in detections) {
      // 设置颜色：手(黄/蓝)，斑马线(橙)，物体(绿)
      if (det.modelName == 'hand') {
        boxPaint.color = Colors.yellowAccent;
      } else if (det.label == 'zebra_crossing' || det.label == 'blind_road') {
        boxPaint.color = Colors.orangeAccent;
      } else {
        boxPaint.color = Colors.greenAccent;
      }

      final rect = Rect.fromLTRB(
        det.boundingBox.left * size.width,
        det.boundingBox.top * size.height,
        det.boundingBox.right * size.width,
        det.boundingBox.bottom * size.height,
      );
      
      canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(4)), boxPaint);

      // 绘制关键点 (如有)
      if (det.landmarks != null) {
        for (var point in det.landmarks!) {
          canvas.drawCircle(Offset(point.dx * size.width, point.dy * size.height), 3, dotPaint);
        }
      }

      // 绘制引导虚线 (手到最近物体的连线)
      if (det.modelName == 'hand') {
        final handCenter = Offset(rect.center.dx, rect.center.dy);
        for (var other in detections) {
          if (other.modelName != 'hand') {
            final objCenter = Offset(other.boundingBox.center.dx * size.width, other.boundingBox.center.dy * size.height);
            _drawDashedLine(canvas, handCenter, objCenter, linePaint);
            break;
          }
        }
      }

      // 绘制标签
      final textPainter = TextPainter(
        text: TextSpan(
          text: ' ${det.label} ', 
          style: TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.bold, backgroundColor: boxPaint.color)
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(canvas, Offset(rect.left, rect.top - 14));
    }
  }

  void _drawDashedLine(Canvas canvas, Offset p1, Offset p2, Paint paint) {
    const double dashWidth = 5.0;
    const double dashSpace = 5.0;
    double distance = (p2 - p1).distance;
    for (double i = 0; i < distance; i += dashWidth + dashSpace) {
      canvas.drawLine(
        p1 + (p2 - p1) * (i / distance),
        p1 + (p2 - p1) * ((i + dashWidth) / distance),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
