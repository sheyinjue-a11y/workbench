package com.example.esp_assistant_v2

import android.graphics.Bitmap
import android.graphics.Color
import kotlin.math.atan2
import kotlin.math.abs

/**
 * 过马路导航核心逻辑。
 * 参考 `workflow_crossstreet.py`
 */
object CrossStreetNavigator {

    /**
     * 计算斑马线的对齐角度和中心偏移。
     * 对应 Python _compute_angle_and_offset
     */
    fun computeAlignment(crosswalkMask: Bitmap?, imageWidth: Int, imageHeight: Int): Map<String, Any?> {
        if (crosswalkMask == null) {
            return mapOf(
                "angle_deg" to 0.0,
                "offset_ratio" to 0.0
            )
        }

        // 简化的斑马线中心计算
        var sumX = 0.0
        var sumY = 0.0
        var count = 0

        // 寻找最底部的斑马线像素点
        var maxBottomY = -1
        var bottomX = -1

        for (y in 0 until crosswalkMask.height step 2) {
            for (x in 0 until crosswalkMask.width step 2) {
                val pixel = crosswalkMask.getPixel(x, y)
                if (pixel != Color.TRANSPARENT && pixel != Color.BLACK) {
                    sumX += x
                    sumY += y
                    count++
                    if (y > maxBottomY) {
                        maxBottomY = y
                        bottomX = x
                    }
                }
            }
        }

        if (count == 0) {
             return mapOf(
                "angle_deg" to 0.0,
                "offset_ratio" to 0.0
            )
        }

        val centerX = sumX / count
        val centerY = sumY / count

        // 近似计算角度：中心点与最底部中心点的连线
        val dy = (maxBottomY - centerY)
        val dx = (bottomX - centerX)
        val angleRad = if (dy > 0) atan2(dx, dy) else 0.0
        val angleDeg = Math.toDegrees(angleRad)

        // 偏移量：最底部点与画面中心线的距离比例
        val offsetRatio = (bottomX - (imageWidth / 2.0)) / imageWidth

        val centerLinePoints = listOf(
            listOf(bottomX, maxBottomY),
            listOf(centerX.toInt(), centerY.toInt())
        )

        return mapOf(
            "angle_deg" to angleDeg,
            "offset_ratio" to offsetRatio,
            "center_line_points" to centerLinePoints,
            "alignment_arrow_start" to listOf(imageWidth / 2, imageHeight),
            "alignment_arrow_end" to listOf(bottomX, maxBottomY)
        )
    }

    /**
     * 判断是否结束过马路。
     * 对应 Python should_switch_to_blindpath
     */
    fun shouldEndCrossing(
        blindPathMask: Bitmap?,
        crosswalkMask: Bitmap?,
        imageWidth: Int,
        imageHeight: Int,
        frameCounter: Int
    ): Boolean {
        // 简单逻辑：如果没有检测到斑马线，但检测到了盲道，且处于画面中下部，则结束过马路
        var blindCount = 0
        var crossCount = 0
        
        if (crosswalkMask != null) {
            for (y in 0 until crosswalkMask.height step 4) {
                for (x in 0 until crosswalkMask.width step 4) {
                    if (crosswalkMask.getPixel(x, y) != Color.TRANSPARENT && crosswalkMask.getPixel(x, y) != Color.BLACK) {
                        crossCount++
                    }
                }
            }
        }

        if (blindPathMask != null) {
            for (y in blindPathMask.height / 2 until blindPathMask.height step 4) {
                for (x in 0 until blindPathMask.width step 4) {
                    if (blindPathMask.getPixel(x, y) != Color.TRANSPARENT && blindPathMask.getPixel(x, y) != Color.BLACK) {
                        blindCount++
                    }
                }
            }
        }

        val hasBlindPathAhead = blindCount > 50
        val lostCrosswalk = crossCount < 20

        return hasBlindPathAhead && lostCrosswalk
    }
}