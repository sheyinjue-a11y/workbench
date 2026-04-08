package com.example.esp_assistant_v2

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.util.Log
import kotlinx.coroutines.*
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.random.Random
import java.util.Locale

const val OVERALL_STATE_IDLE = "IDLE"
const val OVERALL_STATE_CHAT = "CHAT"
const val OVERALL_STATE_BLINDPATH_NAV = "BLINDPATH_NAV"
const val OVERALL_STATE_SEEKING_CROSSWALK = "SEEKING_CROSSWALK"
const val OVERALL_STATE_WAIT_TRAFFIC_LIGHT = "WAIT_TRAFFIC_LIGHT"
const val OVERALL_STATE_CROSSING = "CROSSING"
const val OVERALL_STATE_SEEKING_NEXT_BLINDPATH = "SEEKING_NEXT_BLINDPATH"
const val OVERALL_STATE_RECOVERY = "RECOVERY"
const val OVERALL_STATE_TRAFFIC_LIGHT_DETECTION = "TRAFFIC_LIGHT_DETECTION"
const val OVERALL_STATE_ITEM_SEARCH = "ITEM_SEARCH"

class NavigationHandler(
    private val context: Context,
    private val eventSinkCallback: (Map<String, Any?>) -> Unit,
    private val ttsSpeakCallback: (String) -> Unit
) {
    // 模型抽象接口
    private lateinit var blindPathSegmenter: BlindPathSegmenter
    private lateinit var yoloWorldDetector: YoloWorldDetector
    private lateinit var trafficLightDetector: TrafficLightDetector
    private lateinit var handLandmarker: HandLandmarker
    private lateinit var midasDepthEstimator: MidasDepthEstimator

    // 核心工作流处理器 (用 Kotlin 实现的 Python 逻辑)
    private val blindPathNavigator = BlindPathNavigator()
    private val yoloMediaProcessor = YoloMediaProcessor()

    private var currentOverallState: String = OVERALL_STATE_IDLE
        set(value) {
            if (field != value) {
                Log.d("NavigationHandler", "Overall state changed: $field -> $value")
                field = value
                lastStateChangeTime = System.currentTimeMillis()
            }
        }
    
    private var lastStateChangeTime: Long = 0L

    private var guidanceText: String = ""
    private val visualizations = mutableListOf<Map<String, Any?>>()
    private val stateDetails = ConcurrentHashMap<String, Any?>()

    private var processingJob: Job? = null
    private val scope = CoroutineScope(Dispatchers.Default)

    private var lastGuidanceTime = System.currentTimeMillis()
    private val MIN_TTS_INTERVAL_MS = 1200L

    // 过马路相关
    private var cntCrosswalkSeen: Int = 0
    private var cntAlignReady: Int = 0
    private var cntCrossEnd: Int = 0
    private var lastWaitLightAnnounceTime: Long = 0L
    private val FRAMES_CROSS_SEEN = 8
    private val FRAMES_ALIGN_READY = 12
    private val FRAMES_CROSS_END = 12
    private val FRAMES_NEXT_BLIND_OK = 8
    private val NAV_ORIENTATION_THRESHOLD_DEG = 10.0
    private val NAV_CENTER_OFFSET_THRESHOLD_RATIO = 0.15
    private val COOLDOWN_MS = 600L

    private var targetItemLabel: String? = null
    private var cntLost: Int = 0
    private val FRAMES_LOST_MAX = 45
    private var simulatedFrameCounter = 0

    private var modelsLoaded: Boolean = false

    init {
        loadModels()
    }

    private fun loadModels() {
        try {
            // 初始化真正的带有 session.run() 调用的模型封装类，并传入 context 用于读取 assets
            blindPathSegmenter = RealBlindPathSegmenter(context)
            yoloWorldDetector = RealYoloWorldDetector(context)
            trafficLightDetector = RealTrafficLightDetector(context)
            handLandmarker = RealHandLandmarker()
            midasDepthEstimator = RealMidasDepthEstimator()

            blindPathSegmenter.loadModel("yolo-seg.onnx")
            yoloWorldDetector.loadModel("yoloe-11l-seg.onnx")
            trafficLightDetector.loadModel("trafficlight.onnx")
            handLandmarker.loadModel("hand_landmarker.task")
            midasDepthEstimator.loadModel("midas.tflite")

            yoloWorldDetector.setClasses(ObstacleDetector.WHITELIST_CLASSES)
            modelsLoaded = true
            Log.i("NavigationHandler", "Models loaded successfully.")
        } catch (e: Exception) {
            Log.e("NavigationHandler", "Failed to load models: ${e.message}")
        }
    }

    fun startProcessingLoop() {
        if (!modelsLoaded) return
        if (processingJob?.isActive == true) return
        processingJob = scope.launch {
            while (isActive) {
                val dummyBitmap = Bitmap.createBitmap(640, 480, Bitmap.Config.ARGB_8888)
                processFrame(dummyBitmap)
                delay(100) // 10 FPS
            }
        }
    }

    fun stopProcessingLoop() {
        processingJob?.cancel()
    }

    fun startBlindPathNavigation() {
        resetState()
        currentOverallState = OVERALL_STATE_BLINDPATH_NAV
        blindPathNavigator.currentState = "ONBOARDING"
        blindPathNavigator.onboardingStep = "ROTATION"
        guidanceText = "开始盲道导航，请对准盲道方向。"
        sayGuidance(guidanceText)
    }

    fun stopNavigation() {
        resetState()
        currentOverallState = OVERALL_STATE_CHAT
        guidanceText = "导航已停止，进入对话模式。"
        sayGuidance(guidanceText)
    }

    fun startCrossing() {
        resetState()
        currentOverallState = OVERALL_STATE_CROSSING
        guidanceText = "开始过马路，请直行。"
        sayGuidance(guidanceText)
    }

    fun startTrafficLightDetection() {
        resetState()
        currentOverallState = OVERALL_STATE_TRAFFIC_LIGHT_DETECTION
        guidanceText = "启动红绿灯检测。"
        sayGuidance(guidanceText)
    }

    fun startItemSearch(label: String) {
        resetState()
        targetItemLabel = label
        currentOverallState = OVERALL_STATE_ITEM_SEARCH
        guidanceText = "正在为您寻找$label。"
        sayGuidance(guidanceText)
    }

    fun stopItemSearch(restoreNav: Boolean) {
        val prevState = if (restoreNav) OVERALL_STATE_BLINDPATH_NAV else OVERALL_STATE_CHAT
        resetState()
        currentOverallState = prevState
        guidanceText = "物品寻找已结束。"
        sayGuidance(guidanceText)
    }

    fun onVoiceCommand(command: String) {
        when {
            command.contains("开始导航") || command.contains("盲道导航") -> startBlindPathNavigation()
            command.contains("停止导航") || command.contains("结束") -> stopNavigation()
            command.contains("开始过马路") -> {
                currentOverallState = OVERALL_STATE_WAIT_TRAFFIC_LIGHT
                guidanceText = "等待绿灯。"
                sayGuidance(guidanceText)
            }
            command.contains("立即通过") -> {
                currentOverallState = OVERALL_STATE_CROSSING
                guidanceText = "开始通行。"
                sayGuidance(guidanceText)
            }
            command.contains("看红绿灯") -> startTrafficLightDetection()
            command.contains("帮我找一下") -> {
                startItemSearch(command.substringAfter("帮我找一下").trim())
            }
        }
        sendStateToFlutter()
    }

    fun forceState(newState: String) {
        resetState()
        currentOverallState = newState
        sendStateToFlutter()
    }

    private fun sayGuidance(text: String) {
        if (text.isNotEmpty() && System.currentTimeMillis() - lastGuidanceTime >= MIN_TTS_INTERVAL_MS) {
            ttsSpeakCallback(text)
            lastGuidanceTime = System.currentTimeMillis()
        }
    }

    private fun processFrame(image: Bitmap) {
        simulatedFrameCounter++
        visualizations.clear()

        // 1. 运行核心视觉模型 (这里是对 RealModel 的调用，实际底层调起 ONNX Session.run)
        val (blindPathMask, crosswalkMask) = blindPathSegmenter.segment(image)
        val obstacles = yoloWorldDetector.detectWithPresetClasses(image)
        
        val inCooldown = System.currentTimeMillis() - lastStateChangeTime < COOLDOWN_MS
        val hasBlindPath = blindPathMask != null
        val hasCrosswalk = crosswalkMask != null

        // 丢失状态计数
        if (!hasBlindPath && !hasCrosswalk && currentOverallState in listOf(OVERALL_STATE_BLINDPATH_NAV, OVERALL_STATE_SEEKING_CROSSWALK, OVERALL_STATE_CROSSING)) {
            cntLost++
        } else {
            cntLost = min(0, cntLost - 1)
        }

        if (cntLost >= FRAMES_LOST_MAX && currentOverallState != OVERALL_STATE_RECOVERY) {
            currentOverallState = OVERALL_STATE_RECOVERY
            sayGuidance("环境复杂，感知丢失。")
            cntLost = 0
        }

        when (currentOverallState) {
            OVERALL_STATE_IDLE -> { guidanceText = "系统空闲" }
            OVERALL_STATE_CHAT -> { guidanceText = "对话模式" }
            OVERALL_STATE_BLINDPATH_NAV -> handleBlindPathNavigation(image.width, image.height, blindPathMask, crosswalkMask, obstacles, inCooldown)
            OVERALL_STATE_SEEKING_CROSSWALK -> handleSeekingCrosswalk(image.width, image.height, crosswalkMask, inCooldown)
            OVERALL_STATE_WAIT_TRAFFIC_LIGHT -> handleWaitTrafficLight(image, inCooldown)
            OVERALL_STATE_CROSSING -> handleCrossing(image.width, image.height, blindPathMask, crosswalkMask, inCooldown)
            OVERALL_STATE_SEEKING_NEXT_BLINDPATH -> handleSeekingNextBlindPath(blindPathMask, inCooldown)
            OVERALL_STATE_RECOVERY -> handleRecoveryState(blindPathMask, inCooldown)
            OVERALL_STATE_TRAFFIC_LIGHT_DETECTION -> handleTrafficLightDetection(image)
            OVERALL_STATE_ITEM_SEARCH -> handleItemSearch(image)
        }

        sendStateToFlutter()
    }

    private fun handleBlindPathNavigation(width: Int, height: Int, blindPathMask: Bitmap?, crosswalkMask: Bitmap?, obstacles: List<DetectionResult>, inCooldown: Boolean) {
        // 调用我们刚才创建的真实 Kotlin 导航逻辑
        val result = blindPathNavigator.executeStateMachine(width, height, blindPathMask, obstacles)
        
        stateDetails["currentBlindPathSubState"] = result.first
        guidanceText = result.second
        sayGuidance(guidanceText)

        // 斑马线监控
        val crosswalkStage = CrosswalkMonitor.processFrame(crosswalkMask, blindPathMask)
        if (crosswalkStage == "approaching" || crosswalkStage == "ready") cntCrosswalkSeen++ else cntCrosswalkSeen = min(0, cntCrosswalkSeen - 1)
        
        if (cntCrosswalkSeen >= FRAMES_CROSS_SEEN && !inCooldown) {
            currentOverallState = OVERALL_STATE_SEEKING_CROSSWALK
            sayGuidance("正在接近斑马线，为您对准。")
            cntCrosswalkSeen = 0
        }

        stateDetails["obstacles"] = obstacles.map { mapOf("name" to it.label, "box_coords" to it.box) }
    }

    private fun handleSeekingCrosswalk(width: Int, height: Int, crosswalkMask: Bitmap?, inCooldown: Boolean) {
        val alignment = CrossStreetNavigator.computeAlignment(crosswalkMask, width, height)
        val angle = alignment["angle_deg"] as Double
        val offset = alignment["offset_ratio"] as Double
        
        val aligned = abs(angle) <= NAV_ORIENTATION_THRESHOLD_DEG && abs(offset) <= NAV_CENTER_OFFSET_THRESHOLD_RATIO
        
        if (aligned) cntAlignReady++ else cntAlignReady = min(0, cntAlignReady - 1)

        if (cntAlignReady >= FRAMES_ALIGN_READY && !inCooldown) {
            currentOverallState = OVERALL_STATE_WAIT_TRAFFIC_LIGHT
            sayGuidance("到达斑马线，等待红绿灯。")
            cntAlignReady = 0
        } else {
            if (abs(angle) > NAV_ORIENTATION_THRESHOLD_DEG) {
                sayGuidance(if (angle < 0) "向右转" else "向左转")
            } else if (abs(offset) > NAV_CENTER_OFFSET_THRESHOLD_RATIO) {
                sayGuidance(if (offset < 0) "向右移" else "向左移")
            }
        }
    }

    private fun handleWaitTrafficLight(image: Bitmap, inCooldown: Boolean) {
        val results = trafficLightDetector.detect(image)
        val color = results.firstOrNull { it.label in listOf("red", "green", "yellow") }?.label ?: "unknown"

        if (color == "green" && !inCooldown) {
            currentOverallState = OVERALL_STATE_CROSSING
            sayGuidance("绿灯亮起，开始通行。")
        } else {
            if (System.currentTimeMillis() - lastWaitLightAnnounceTime > 5000L) {
                sayGuidance("红灯请等待。")
                lastWaitLightAnnounceTime = System.currentTimeMillis()
            }
        }
        stateDetails["traffic_light_color"] = color
    }

    private fun handleCrossing(width: Int, height: Int, blindPathMask: Bitmap?, crosswalkMask: Bitmap?, inCooldown: Boolean) {
        val alignment = CrossStreetNavigator.computeAlignment(crosswalkMask, width, height)
        val angle = alignment["angle_deg"] as Double
        val offset = alignment["offset_ratio"] as Double

        if (abs(angle) > NAV_ORIENTATION_THRESHOLD_DEG) {
            sayGuidance(if (angle < 0) "注意偏航，向右微调" else "注意偏航，向左微调")
        } else if (abs(offset) > NAV_CENTER_OFFSET_THRESHOLD_RATIO) {
            sayGuidance(if (offset < 0) "向左平移" else "向右平移")
        } else {
            sayGuidance("过马路中，保持直行")
        }

        val shouldEnd = CrossStreetNavigator.shouldEndCrossing(blindPathMask, crosswalkMask, width, height, simulatedFrameCounter)
        if (shouldEnd) cntCrossEnd++ else cntCrossEnd = min(0, cntCrossEnd - 1)

        if (cntCrossEnd >= FRAMES_CROSS_END && !inCooldown) {
            currentOverallState = OVERALL_STATE_SEEKING_NEXT_BLINDPATH
            sayGuidance("过马路结束，寻找盲道。")
            cntCrossEnd = 0
        }
    }

    private fun handleSeekingNextBlindPath(blindPathMask: Bitmap?, inCooldown: Boolean) {
        if (blindPathMask != null) {
            currentOverallState = OVERALL_STATE_BLINDPATH_NAV
            sayGuidance("找到盲道，继续导航。")
        }
    }

    private fun handleRecoveryState(blindPathMask: Bitmap?, inCooldown: Boolean) {
        if (blindPathMask != null && !inCooldown) {
            currentOverallState = OVERALL_STATE_BLINDPATH_NAV
            sayGuidance("感知恢复。")
        }
    }

    private fun handleTrafficLightDetection(image: Bitmap) {
        val results = trafficLightDetector.detect(image)
        val color = results.firstOrNull()?.label ?: "未知"
        sayGuidance("当前信号灯：$color")
    }

    private fun handleItemSearch(image: Bitmap) {
        val results = yoloWorldDetector.detect(image, listOf(targetItemLabel ?: ""))
        val targetItem = results.firstOrNull()
        val handLandmarks = handLandmarker.detect(image)

        // 调度 YoloMediaProcessor (寻物逻辑翻译版)
        guidanceText = yoloMediaProcessor.processFrame(
            targetItemLabel, image.width, image.height, targetItem, handLandmarks
        )
        sayGuidance(guidanceText)
        
        stateDetails["yolomedia_mode"] = yoloMediaProcessor.mode
        stateDetails["is_grabbing"] = yoloMediaProcessor.isGrabbing
    }

    private fun sendStateToFlutter() {
        val dataToSend = mutableMapOf<String, Any?>(
            "currentOverallState" to currentOverallState,
            "guidanceText" to guidanceText,
            "visualizations" to visualizations,
            "stateDetails" to stateDetails
        )
        eventSinkCallback(dataToSend)
    }

    private fun resetState() {
        currentOverallState = OVERALL_STATE_IDLE
        blindPathNavigator.currentState = "ONBOARDING"
        yoloMediaProcessor.mode = "SEGMENT"
        guidanceText = ""
        visualizations.clear()
        stateDetails.clear()
        cntCrosswalkSeen = 0
        cntAlignReady = 0
        cntCrossEnd = 0
        cntLost = 0
    }
}
