package com.example.esp_assistant_v2

import android.graphics.Bitmap
import android.graphics.Color
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.PI

/**
 * 盲道导航核心工作流类。
 * 严格参考 Python 项目中的 `legacy_python_ref/core_files/workflow_blindpath.py` 实现。
 */
class BlindPathNavigator {

    // --- 状态常量 (对应 Python STATE_*) ---
    var currentState = "ONBOARDING"
    var onboardingStep = "ROTATION"
    var maneuverStep = "ISSUE_COMMAND"

    // --- 阈值参数 (对应 Python 中的参数) ---
    private val ONBOARDING_ALIGN_THRESHOLD_RATIO = 0.1
    private val ONBOARDING_CENTER_OFFSET_THRESHOLD_RATIO = 0.15
    private val NAV_ORIENTATION_THRESHOLD_RAD = Math.toRadians(10.0) // 10度
    private val NAV_CENTER_OFFSET_THRESHOLD_RATIO = 0.15
    private val CURVATURE_PROXY_THRESHOLD = 5e-5

    // --- 历史缓存 ---
    private val centerlineHistory = mutableListOf<List<CenterPoint>>()
    private val HISTORY_MAX = 5

    // --- 数据类 ---
    data class CenterPoint(val y: Int, val x: Double, val width: Double)
    data class PathFeatures(
        val centerlineData: List<CenterPoint>,
        val tangentAngleRad: Double,
        val centerOffsetRatio: Double,
        val curvatureProxy: Double,
        val arrowStart: Pair<Int, Int>,
        val arrowEnd: Pair<Int, Int>
    )

    /**
     * 核心处理函数，执行状态机。
     * 对应 Python 的 `_execute_state_machine`
     */
    fun executeStateMachine(
        imageWidth: Int,
        imageHeight: Int,
        blindPathMask: Bitmap?,
        obstacles: List<DetectionResult>
    ): Pair<String, String> { // 返回: Pair<当前子状态, 语音引导>
        var guidanceText = ""

        if (blindPathMask == null || countNonZero(blindPathMask) < 100) {
            return Pair(currentState, "") // 掩码丢失，交由外部处理 (如 navigation_master 的 RECOVERY)
        }

        // 1. 提取像素域特征 (对应 Python _get_pixel_domain_features)
        val features = getPixelDomainFeatures(blindPathMask) ?: return Pair(currentState, "路径特征提取失败")

        // 2. 避障检测 (对应 Python 中 _check_obstacles 并在 navigating 中处理)
        // 提取近距离障碍物
        val nearObstacles = obstacles.filter { ObstacleDetector.isNearObstacle(it, imageWidth, imageHeight) }

        // 如果在导航或上盲道过程中遇到障碍物，进入避障 (简化逻辑)
        if (nearObstacles.isNotEmpty() && (currentState == "NAVIGATING" || currentState == "ONBOARDING")) {
            if (currentState != "AVOIDING_OBSTACLE" && currentState != "LOCKING_ON") {
                currentState = "LOCKING_ON"
                guidanceText = "检测到前方有障碍物，正在锁定。"
                return Pair(currentState, guidanceText)
            }
        }

        // 3. 执行状态机分支
        when (currentState) {
            "ONBOARDING" -> {
                guidanceText = handleOnboarding(features, imageWidth, imageHeight)
            }
            "NAVIGATING" -> {
                guidanceText = handleNavigating(features, imageWidth)
            }
            "MANEUVERING_TURN" -> {
                // 转弯逻辑简化
                currentState = "NAVIGATING" 
                guidanceText = "转弯处理完成，继续导航。"
            }
            "LOCKING_ON" -> {
                currentState = "AVOIDING_OBSTACLE"
                guidanceText = "开始避障，请向侧方移动。"
            }
            "AVOIDING_OBSTACLE" -> {
                if (nearObstacles.isEmpty()) {
                    currentState = "NAVIGATING"
                    guidanceText = "障碍物已清除，回到盲道导航。"
                } else {
                    guidanceText = "请继续避让。"
                }
            }
        }

        return Pair(currentState, guidanceText)
    }

    /**
     * 处理上盲道逻辑 (像素域方法)。
     * 对应 Python `_handle_pixel_domain_onboarding`。
     */
    private fun handleOnboarding(features: PathFeatures, imageWidth: Int, imageHeight: Int): String {
        val imageCenterX = imageWidth / 2.0
        val orientationErrorRad = features.tangentAngleRad
        
        // 获取画面底部的中心点偏移
        val bottomPoint = features.centerlineData.firstOrNull() // Y 最大的点（最底部）
        val targetXBottom = bottomPoint?.x ?: imageCenterX
        val centerOffsetRatio = abs(targetXBottom - imageCenterX) / imageWidth

        var guidanceText = ""

        if (onboardingStep == "ROTATION") {
            if (abs(orientationErrorRad) < ONBOARDING_ALIGN_THRESHOLD_RATIO) { // 借用比例作为弧度阈值的简写
                guidanceText = "方向已对正！现在校准位置。"
                onboardingStep = "TRANSLATION"
            } else {
                guidanceText = if (orientationErrorRad > 0) "请向左转动。" else "请向右转动。"
            }
        } else if (onboardingStep == "TRANSLATION") {
            if (centerOffsetRatio < ONBOARDING_CENTER_OFFSET_THRESHOLD_RATIO) {
                guidanceText = "校准完成！您已在盲道上，开始前行。"
                currentState = "NAVIGATING"
                onboardingStep = "ROTATION" // 重置
            } else {
                guidanceText = if (targetXBottom < imageCenterX) "请向左平移。" else "请向右平移。"
            }
        }

        return guidanceText
    }

    /**
     * 处理常规导航逻辑。
     * 对应 Python `_generate_navigation_guidance`。
     */
    private fun handleNavigating(features: PathFeatures, imageWidth: Int): String {
        val orientationErrorRad = features.tangentAngleRad
        val centerOffsetRatio = features.centerOffsetRatio

        return if (abs(orientationErrorRad) > NAV_ORIENTATION_THRESHOLD_RAD) {
            if (orientationErrorRad > 0) "请向左转。" else "请向右转。"
        } else if (abs(centerOffsetRatio) > NAV_CENTER_OFFSET_THRESHOLD_RATIO) {
            if (centerOffsetRatio > 0) "请向右微调。" else "请向左微调。" // offsetRatio = (targetX - centerX)/width
        } else {
            "保持直行" // Python 中的平滑节流由 NavigationHandler 或 Dart 处理
        }
    }

    /**
     * 提取像素域特征。
     * 对应 Python `workflow_blindpath.py` 的 `_get_pixel_domain_features`。
     * 提取中心线，进行平滑，计算切线角度和中心偏移。
     */
    fun getPixelDomainFeatures(mask: Bitmap): PathFeatures? {
        val height = mask.height
        val width = mask.width
        val rawCenterline = mutableListOf<CenterPoint>()

        // 1. 逐行扫描提取中心点
        for (y in height - 1 downTo (height * 0.3).toInt() step 5) {
            var minX = -1
            var maxX = -1
            for (x in 0 until width) {
                val pixel = mask.getPixel(x, y)
                if (pixel != Color.TRANSPARENT && pixel != Color.BLACK) {
                    if (minX == -1) minX = x
                    maxX = x
                }
            }
            if (minX != -1 && maxX != -1 && (maxX - minX) > 10) {
                val pathWidth = (maxX - minX).toDouble()
                val centerX = (minX + maxX) / 2.0
                rawCenterline.add(CenterPoint(y, centerX, pathWidth))
            }
        }

        if (rawCenterline.size < 10) return null

        // 2. 时间和空间平滑 (模拟 Python _smooth_centerline)
        val smoothedCenterline = smoothCenterline(rawCenterline)

        // 3. 计算切线角度和偏移 (使用线性回归近似替代二次多项式拟合以提升移动端性能)
        // 目标是找出 y 对 x 的关系，或者为了符合直觉，用最小二乘法拟合直线 x = m*y + c
        var sumY = 0.0; var sumX = 0.0; var sumYY = 0.0; var sumYX = 0.0
        val n = smoothedCenterline.size.toDouble()

        smoothedCenterline.forEach { pt ->
            sumY += pt.y
            sumX += pt.x
            sumYY += pt.y * pt.y
            sumYX += pt.y * pt.x
        }

        // x = m * y + c
        val denominator = n * sumYY - sumY * sumY
        var slopeMY = 0.0
        if (abs(denominator) > 1e-6) {
            slopeMY = (n * sumYX - sumY * sumX) / denominator
        }

        // 图像中 Y 是向下的。计算与垂直向上的夹角
        // dx = m * dy. 
        // 向前看：dy 是负数 (比如 -100)，对应的 dx = slopeMY * (-100).
        // angle = atan2(dx, -dy) 
        val lookaheadDy = -100.0
        val expectedDx = slopeMY * lookaheadDy
        val tangentAngleRad = atan2(expectedDx, -lookaheadDy)

        // 计算目标点 (取中心偏下的点作为基准)
        val targetPoint = smoothedCenterline[smoothedCenterline.size / 2]
        val centerOffsetPixels = targetPoint.x - (width / 2.0)
        val centerOffsetRatio = centerOffsetPixels / width.toDouble()

        // 4. 构建可视化箭头
        val arrowStartX = width / 2
        val arrowStartY = height
        val arrowLength = 100
        val arrowEndX = (arrowStartX + arrowLength * kotlin.math.sin(tangentAngleRad)).toInt()
        val arrowEndY = (arrowStartY - arrowLength * kotlin.math.cos(tangentAngleRad)).toInt()

        return PathFeatures(
            centerlineData = smoothedCenterline,
            tangentAngleRad = tangentAngleRad,
            centerOffsetRatio = centerOffsetRatio,
            curvatureProxy = 0.0, // 线性拟合曲率为0
            arrowStart = Pair(arrowStartX, arrowStartY),
            arrowEnd = Pair(arrowEndX, arrowEndY)
        )
    }

    private fun smoothCenterline(current: List<CenterPoint>): List<CenterPoint> {
        centerlineHistory.add(current)
        if (centerlineHistory.size > HISTORY_MAX) {
            centerlineHistory.removeAt(0)
        }
        
        // 简单空间平滑 (滑动窗口)
        val result = mutableListOf<CenterPoint>()
        val windowSize = 3
        for (i in current.indices) {
            val startIdx = maxOf(0, i - windowSize / 2)
            val endIdx = minOf(current.size - 1, i + windowSize / 2)
            var sumX = 0.0; var sumW = 0.0
            val count = endIdx - startIdx + 1
            for (j in startIdx..endIdx) {
                sumX += current[j].x
                sumW += current[j].width
            }
            result.add(CenterPoint(current[i].y, sumX / count, sumW / count))
        }
        return result
    }

    private fun countNonZero(bitmap: Bitmap): Int {
        var count = 0
        for (y in 0 until bitmap.height step 2) { // 步长2加速计算
            for (x in 0 until bitmap.width step 2) {
                val pixel = bitmap.getPixel(x, y)
                if (pixel != Color.TRANSPARENT && pixel != Color.BLACK) count++
            }
        }
        return count * 4
    }
}