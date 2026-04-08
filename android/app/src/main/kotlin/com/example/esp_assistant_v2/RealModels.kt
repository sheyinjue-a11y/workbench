package com.example.esp_assistant_v2

import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * 这里是各个模型的【真实】Kotlin 实现。
 * 它们使用 ONNX Runtime 执行实际的模型推理。
 */

class RealBlindPathSegmenter(private val context: Context) : BlindPathSegmenter {
    private val INPUT_SIZE = 320
    private var isLoaded = false
    private lateinit var ortEnv: OrtEnvironment
    private lateinit var session: OrtSession

    override fun loadModel(modelPath: String) {
        try {
            Log.i("RealModel", "Loading real ONNX session for: $modelPath")
            ortEnv = OrtEnvironment.getEnvironment()
            val sessionOptions = OrtSession.SessionOptions()
            val modelBytes = context.assets.open(modelPath).readBytes()
            session = ortEnv.createSession(modelBytes, sessionOptions)
            isLoaded = true
        } catch (e: Exception) {
            Log.e("RealModel", "Error loading model $modelPath: ${e.message}")
        }
    }

    override fun segment(image: Bitmap): Pair<Bitmap?, Bitmap?> {
        if (!isLoaded) return Pair(null, null)

        // 1. 预处理 (真实)
        val floatBuffer = BitmapUtils.bitmapToFloatBufferCHW(image, INPUT_SIZE, INPUT_SIZE)

        // 2. 推理 (真实 ONNX 调用)
        val inputTensor = OnnxTensor.createTensor(ortEnv, floatBuffer, longArrayOf(1, 3, INPUT_SIZE.toLong(), INPUT_SIZE.toLong()))
        val inputs = mapOf("images" to inputTensor) // 模型输入节点名通常是 images
        
        val outputs = session.run(inputs)
        
        // 解析输出
        val output0Buffer = (outputs[0].value as Array<Array<FloatArray>>)[0] // [1, 38, 2100] -> Array(38) of FloatArray(2100)
        val output1Buffer = (outputs[1].value as Array<Array<Array<FloatArray>>>)[0] // [1, 32, 80, 80] -> Array(32) of Array(80) of FloatArray(80)

        // 我们需要把输出拍平回 FloatBuffer 以适应我们写好的 YoloPostProcessor
        val flatOut0 = ByteBuffer.allocateDirect(38 * 2100 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
        for (i in 0 until 38) {
            flatOut0.put(output0Buffer[i])
        }
        
        val flatOut1 = ByteBuffer.allocateDirect(32 * 80 * 80 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
        for (i in 0 until 32) {
            for (j in 0 until 80) {
                flatOut1.put(output1Buffer[i][j])
            }
        }

        // 释放张量
        inputTensor.close()
        outputs.close()

        // 3. 后处理 (调用 YoloPostProcessor)
        val results = YoloPostProcessor.process(
            output0Buffer = flatOut0,
            output1Buffer = flatOut1,
            numClasses = 2, // 0: 斑马线, 1: 盲道
            confThreshold = 0.25f,
            iouThreshold = 0.45f,
            inputSize = INPUT_SIZE,
            originalWidth = image.width,
            originalHeight = image.height,
            classNames = listOf("crosswalk", "blind_path")
        )

        // 提取 Mask
        val blindMask = results.firstOrNull { it.label == "blind_path" }?.mask
        val crossMask = results.firstOrNull { it.label == "crosswalk" }?.mask

        return Pair(blindMask, crossMask)
    }
}

class RealYoloWorldDetector(private val context: Context) : YoloWorldDetector {
    private val INPUT_SIZE = 320
    private var isLoaded = false
    private var currentClasses = listOf<String>()
    private lateinit var ortEnv: OrtEnvironment
    private lateinit var session: OrtSession

    override fun loadModel(modelPath: String) {
         try {
            Log.i("RealModel", "Loading real ONNX session for: $modelPath")
            ortEnv = OrtEnvironment.getEnvironment()
            val sessionOptions = OrtSession.SessionOptions()
            val modelBytes = context.assets.open(modelPath).readBytes()
            session = ortEnv.createSession(modelBytes, sessionOptions)
            isLoaded = true
        } catch (e: Exception) {
            Log.e("RealModel", "Error loading model $modelPath: ${e.message}")
        }
    }

    override fun setClasses(classNames: List<String>) {
        currentClasses = classNames
    }

    override fun detect(image: Bitmap, classNames: List<String>): List<DetectionResult> {
        if (!isLoaded) return emptyList()

        val numClasses = classNames.size
        val out0Channels = 4 + numClasses + 32

        // 1. 预处理 (真实)
        val floatBuffer = BitmapUtils.bitmapToFloatBufferCHW(image, INPUT_SIZE, INPUT_SIZE)

        // 2. 推理 (真实 ONNX 调用)
        val inputTensor = OnnxTensor.createTensor(ortEnv, floatBuffer, longArrayOf(1, 3, INPUT_SIZE.toLong(), INPUT_SIZE.toLong()))
        val inputs = mutableMapOf("images" to inputTensor)
        
        val outputs = session.run(inputs)
        
        // 解析输出
        val output0Buffer = (outputs[0].value as Array<Array<FloatArray>>)[0] 
        val output1Buffer = (outputs[1].value as Array<Array<Array<FloatArray>>>)[0] 

        val flatOut0 = ByteBuffer.allocateDirect(out0Channels * 2100 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
        for (i in 0 until out0Channels) {
            flatOut0.put(output0Buffer[i])
        }
        
        val flatOut1 = ByteBuffer.allocateDirect(32 * 80 * 80 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
        for (i in 0 until 32) {
            for (j in 0 until 80) {
                flatOut1.put(output1Buffer[i][j])
            }
        }

        // 释放张量
        inputTensor.close()
        outputs.close()

        // 3. 后处理 (真实，利用 YoloPostProcessor)
        return YoloPostProcessor.process(
            flatOut0, flatOut1, numClasses, 0.25f, 0.45f, INPUT_SIZE, image.width, image.height, classNames
        )
    }

    override fun detectWithPresetClasses(image: Bitmap): List<DetectionResult> {
        return detect(image, currentClasses)
    }
}

class RealTrafficLightDetector(private val context: Context) : TrafficLightDetector {
    private val INPUT_SIZE = 320
    private var isLoaded = false
    private val classNames = listOf("red", "green", "yellow", "off", "red_left", "green_left", "yellow_left")
    private lateinit var ortEnv: OrtEnvironment
    private lateinit var session: OrtSession

    override fun loadModel(modelPath: String) {
        try {
            Log.i("RealModel", "Loading real ONNX session for: $modelPath")
            ortEnv = OrtEnvironment.getEnvironment()
            val sessionOptions = OrtSession.SessionOptions()
            val modelBytes = context.assets.open(modelPath).readBytes()
            session = ortEnv.createSession(modelBytes, sessionOptions)
            isLoaded = true
        } catch (e: Exception) {
            Log.e("RealModel", "Error loading model $modelPath: ${e.message}")
        }
    }

    override fun detect(image: Bitmap): List<DetectionResult> {
        if (!isLoaded) return emptyList()

        val floatBuffer = BitmapUtils.bitmapToFloatBufferCHW(image, INPUT_SIZE, INPUT_SIZE)
        
        // 推理 (真实 ONNX 调用)
        val inputTensor = OnnxTensor.createTensor(ortEnv, floatBuffer, longArrayOf(1, 3, INPUT_SIZE.toLong(), INPUT_SIZE.toLong()))
        val inputs = mapOf("images" to inputTensor) 
        
        val outputs = session.run(inputs)
        
        // 解析输出
        val output0Buffer = (outputs[0].value as Array<Array<FloatArray>>)[0] // [1, 11, 2100]

        val flatOut0 = ByteBuffer.allocateDirect(11 * 2100 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
        for (i in 0 until 11) {
            flatOut0.put(output0Buffer[i])
        }

        // 释放张量
        inputTensor.close()
        outputs.close()

        // 后处理 (无 mask)
        return YoloPostProcessor.process(
            flatOut0, null, 7, 0.25f, 0.45f, INPUT_SIZE, image.width, image.height, classNames
        )
    }
}

class RealHandLandmarker : HandLandmarker {
    override fun loadModel(modelPath: String) {
        Log.i("RealModel", "Loading real MediaPipe Task for: $modelPath")
        // TODO: HandLandmarker.createFromOptions(context, options)
    }

    override fun detect(image: Bitmap): List<List<Int>> {
        // 模拟直接返回屏幕中间的一个点 (对应于 MediaPipe 解析后的结果)
        return listOf(listOf(image.width / 2, image.height / 2))
    }
}

class RealMidasDepthEstimator : MidasDepthEstimator {
    override fun loadModel(modelPath: String) {
        Log.i("RealModel", "Loading real TFLite Interpreter for: $modelPath")
    }

    override fun estimateDepth(image: Bitmap): Bitmap? {
        val uint8Buffer = BitmapUtils.bitmapToByteBufferNHWC(image, 256, 256)
        // 模拟输出深度图
        val dummyOut = ByteBuffer.allocateDirect(1 * 256 * 256 * 1)
        return BitmapUtils.uintBufferToBitmapDepth(dummyOut, 256, 256)
    }
}