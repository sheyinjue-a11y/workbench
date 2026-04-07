// lib/services/video_service.dart
import 'dart:async';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

class VideoService {
  final String espIP;
  final StreamController<Uint8List> _frameController = StreamController.broadcast();
  Stream<Uint8List> get frameStream => _frameController.stream;

  http.Client? _client;
  bool _running = false;
  List<int> _buffer = [];
  int _frameCount = 0;

  VideoService({required this.espIP}) {
    print('📹 VideoService 实例创建，IP: $espIP');
  }

  Future<void> start() async {
    print('📹 start() 被调用');
    if (_running) {
      print('⚠️ 已经在运行中');
      return;
    }
    _running = true;
    _buffer.clear();

    final url = 'http://$espIP/stream';
    print('📹 正在连接: $url');

    try {
      _client = http.Client();
      final request = http.Request('GET', Uri.parse(url));
      final response = await _client!.send(request).timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          print('❌ 连接超时');
          throw TimeoutException('连接超时');
        },
      );

      print('📹 响应状态码: ${response.statusCode}');

      if (response.statusCode == 200) {
        print('✅ 连接成功，开始接收数据流');

        await for (var chunk in response.stream) {
          if (!_running) break;
          _buffer.addAll(chunk);
          _extractFrames();
        }
      } else {
        print('❌ HTTP 错误: ${response.statusCode}');
      }
    } catch (e) {
      print('❌ 视频流错误: $e');
    } finally {
      _running = false;
      print('📹 视频流结束');
    }
  }

  void _extractFrames() {
    int start = -1, end = -1;
    for (int i = 0; i < _buffer.length - 1; i++) {
      if (_buffer[i] == 0xFF && _buffer[i + 1] == 0xD8) start = i;
      if (start != -1 && _buffer[i] == 0xFF && _buffer[i + 1] == 0xD9) {
        end = i + 1;
        break;
      }
    }
    if (start != -1 && end != -1) {
      final frame = _buffer.sublist(start, end + 1);
      _frameController.add(Uint8List.fromList(frame));
      _buffer.removeRange(0, end + 1);
      if (++_frameCount % 10 == 0) {
        print('📸 已接收 $_frameCount 帧，最新帧大小: ${frame.length} bytes');
      }
    }
  }

  void stop() {
    print('⏹️ stop() 被调用');
    _running = false;
    _client?.close();
    _buffer.clear();
  }

  void dispose() {
    print('🗑️ dispose() 被调用');
    stop();
    _frameController.close();
  }
}