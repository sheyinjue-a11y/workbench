import 'package:flutter_tts/flutter_tts.dart';

class TTSService {
  final FlutterTts _tts = FlutterTts();
  bool _speaking = false;

  Future<void> init() async {
    await _tts.setLanguage("zh-CN");
    await _tts.setSpeechRate(0.5);
    await _tts.setPitch(1.0);
    await _tts.setVolume(1.0);
    _tts.setCompletionHandler(() => _speaking = false);
  }

  Future<void> speak(String text) async {
    if (_speaking) await _tts.stop();
    _speaking = true;
    await _tts.speak(text);
  }

  void dispose() => _tts.stop();
}