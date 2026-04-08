package com.example.esp_assistant_v2

import kotlin.math.abs

/**
 * 物品寻找和交互逻辑。
 * 对应 Python `yolomedia.py`
 */
class YoloMediaProcessor {

    var mode: String = "SEGMENT" // SEGMENT, FLASH, CENTER_GUIDE, TRACK
    var isGrabbing: Boolean = false
    var handToTargetDirection: String? = null
    var targetDirection: String? = null
    var targetDistance: String? = null

    /**
     * 执行寻物状态机。
     */
    fun processFrame(
        targetLabel: String?,
        imageWidth: Int,
        imageHeight: Int,
        targetItem: DetectionResult?,
        handLandmarks: List<List<Int>>
    ): String { // 返回 GuidanceText
        var guidanceText = ""

        if (targetLabel == null) return "目标为空"

        if (targetItem == null) {
            mode = "SEGMENT"
            targetDirection = null
            targetDistance = "未知"
            handToTargetDirection = null
            isGrabbing = false
            return "正在图像中寻找 $targetLabel。请缓慢环顾。"
        }

        // 目标存在，进行居中判定和距离估算
        val box = targetItem.box ?: return "目标包围框异常"
        val centerX = (box[0] + box[2]) / 2.0
        val centerY = (box[1] + box[3]) / 2.0
        val areaRatio = ObstacleDetector.calculateAreaRatio(targetItem, imageWidth, imageHeight)
        val bottomYRatio = ObstacleDetector.calculateBottomYRatio(targetItem, imageHeight)

        val isCentered = abs(centerX - imageWidth / 2.0) < imageWidth * 0.1 && abs(centerY - imageHeight / 2.0) < imageHeight * 0.1
        val isClose = bottomYRatio > 0.8 || areaRatio > 0.2

        targetDirection = when {
            isCentered -> "正前方"
            centerX < imageWidth / 2.0 - imageWidth * 0.1 -> "左侧"
            centerX > imageWidth / 2.0 + imageWidth * 0.1 -> "右侧"
            centerY < imageHeight / 2.0 - imageHeight * 0.1 -> "上方"
            else -> "下方"
        }
        targetDistance = if (isClose) "已很近" else "较远处"

        // 手部引导
        if (handLandmarks.isNotEmpty()) {
            val handX = handLandmarks[0][0].toDouble()
            val handY = handLandmarks[0][1].toDouble()

            val handOffsetX = handX - centerX
            val handOffsetY = handY - centerY

            if (abs(handOffsetX) < 30 && abs(handOffsetY) < 30) {
                handToTargetDirection = "aligned"
                isGrabbing = true // 简化抓取检测：手和物品重合即视为抓取
            } else {
                handToTargetDirection = when {
                    handOffsetX < -30 -> "right"
                    handOffsetX > 30 -> "left"
                    handOffsetY < -30 -> "down"
                    else -> "up"
                }
                isGrabbing = false
            }
        } else {
            handToTargetDirection = null
            isGrabbing = false
        }

        // 状态机演进和语音生成
        if (isGrabbing) {
            mode = "FLASH"
            guidanceText = "检测到您已抓取 $targetLabel，是否结束寻找？"
        } else if (handToTargetDirection == "aligned") {
            mode = "TRACK"
            guidanceText = "手部已对准 $targetLabel，可以尝试抓取。"
        } else if (handToTargetDirection != null) {
            mode = "TRACK"
            guidanceText = "请将手往 ${handToTargetDirection.toCnDirection()} 移动，靠近 $targetLabel。"
        } else {
            mode = if (isCentered && isClose) "FLASH" else if (isCentered) "CENTER_GUIDE" else "SEGMENT"
            guidanceText = "$targetLabel 在您$targetDirection，看起来$targetDistance。"
        }

        return guidanceText
    }
}