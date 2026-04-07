import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

class ModelLoader {
  static Future<OrtSession> loadModel(String assetPath) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/${assetPath.split('/').last}');
    if (!await file.exists()) {
      final data = await rootBundle.load(assetPath);
      await file.writeAsBytes(data.buffer.asUint8List());
    }
    final ort = OnnxRuntime();
    return await ort.createSession(file.path);
  }
}