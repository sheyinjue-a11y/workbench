package com.example.esp_assistant_v2

import android.graphics.Bitmap
import android.graphics.Color
import java.nio.FloatBuffer
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min

/**
 * 通用的 YOLOv8 目标检测与实例分割后处理工具类。
 * 旨在用纯 Kotlin 替代 Python 中基于 Numpy 和 OpenCV 的后处理。
 */
object YoloPostProcessor {

    /**
     * 表示一个尚未经过 NMS 过滤的检测框。
     */
    data class BBox(
        val x1: Float, val y1: Float, val x2: Float, val y2: Float,
        val score: Float,
        val classId: Int,
        val maskCoeffs: FloatArray? = null
    )

    /**
     * 解析 YOLOv8 的输出张量 (output0 和 output1)，返回结构化的 DetectionResult 列表。
     *
     * @param output0Buffer 检测头输出，形状通常为 [1, 4+num_classes+32, 2100]。
     * @param output1Buffer Mask Protos 输出，形状通常为 [1, 32, 80, 80] (如果为 null，表示仅检测模型)。
     * @param numClasses 类别数量。
     * @param confThreshold 置信度阈值。
     * @param iouThreshold NMS IoU 阈值。
     * @param inputSize 模型输入尺寸 (如 320)。
     * @param originalWidth 原始图像宽度 (用于恢复坐标和掩码尺寸)。
     * @param originalHeight 原始图像高度。
     * @param classNames 类别名称列表 (用于映射 classId 到名称)。
     */
    fun process(
        output0Buffer: FloatBuffer,
        output1Buffer: FloatBuffer?,
        numClasses: Int,
        confThreshold: Float,
        iouThreshold: Float,
        inputSize: Int,
        originalWidth: Int,
        originalHeight: Int,
        classNames: List<String>? = null
    ): List<DetectionResult> {
        val boxes = decodeBoxes(output0Buffer, numClasses, confThreshold, inputSize, output1Buffer != null)
        val nmsBoxes = nonMaxSuppression(boxes, iouThreshold)

        val results = mutableListOf<DetectionResult>()
        val scaleX = originalWidth.toFloat() / inputSize
        val scaleY = originalHeight.toFloat() / inputSize

        for (box in nmsBoxes) {
            // 恢复到原始图像坐标
            val origX1 = (box.x1 * scaleX).toInt().coerceIn(0, originalWidth - 1)
            val origY1 = (box.y1 * scaleY).toInt().coerceIn(0, originalHeight - 1)
            val origX2 = (box.x2 * scaleX).toInt().coerceIn(0, originalWidth - 1)
            val origY2 = (box.y2 * scaleY).toInt().coerceIn(0, originalHeight - 1)
            
            // 如果框无效，跳过
            if (origX2 <= origX1 || origY2 <= origY1) continue

            val label = classNames?.getOrNull(box.classId) ?: box.classId.toString()
            var maskBitmap: Bitmap? = null

            // 如果有 output1 且有 maskCoeffs，处理分割掩码
            if (output1Buffer != null && box.maskCoeffs != null) {
                maskBitmap = processMask(
                    box.maskCoeffs,
                    output1Buffer,
                    box.x1, box.y1, box.x2, box.y2, // 传入相对于 inputSize 的坐标
                    inputSize,
                    origX1, origY1, origX2, origY2, // 传入恢复后的原始坐标
                    originalWidth, originalHeight
                )
            }

            results.add(
                DetectionResult(
                    label = label,
                    confidence = box.score,
                    box = listOf(origX1, origY1, origX2, origY2),
                    mask = maskBitmap
                )
            )
        }
        return results
    }

    /**
     * 解码 output0 获取所有候选边界框。
     * output0 形状: [1, rows, cols] -> rows = 4(bbox) + numClasses + (32 if hasMask else 0), cols = 2100(anchors)
     */
    private fun decodeBoxes(
        output0Buffer: FloatBuffer,
        numClasses: Int,
        confThreshold: Float,
        inputSize: Int,
        hasMask: Boolean
    ): List<BBox> {
        val boxes = mutableListOf<BBox>()
        output0Buffer.rewind()
        
        val rows = 4 + numClasses + (if (hasMask) 32 else 0)
        val cols = output0Buffer.capacity() / rows // 推断出锚点数量，通常是 2100 或 8400

        // output0 是按行存储的：先是所有 anchor 的 x，再是 y，w, h，然后是各类的 score，最后是 mask_coeffs
        // 为了方便处理，我们需要按列 (anchor) 访问

        for (c in 0 until cols) {
            // 获取最高的分数和对应的类别
            var maxScore = -1f
            var maxClassId = -1
            for (r in 4 until 4 + numClasses) {
                val score = output0Buffer.get(r * cols + c)
                if (score > maxScore) {
                    maxScore = score
                    maxClassId = r - 4
                }
            }

            if (maxScore > confThreshold) {
                val cx = output0Buffer.get(0 * cols + c)
                val cy = output0Buffer.get(1 * cols + c)
                val w = output0Buffer.get(2 * cols + c)
                val h = output0Buffer.get(3 * cols + c)

                val x1 = cx - w / 2f
                val y1 = cy - h / 2f
                val x2 = cx + w / 2f
                val y2 = cy + h / 2f

                var maskCoeffs: FloatArray? = null
                if (hasMask) {
                    maskCoeffs = FloatArray(32)
                    for (i in 0 until 32) {
                        maskCoeffs[i] = output0Buffer.get((4 + numClasses + i) * cols + c)
                    }
                }

                boxes.add(BBox(x1, y1, x2, y2, maxScore, maxClassId, maskCoeffs))
            }
        }
        return boxes
    }

    /**
     * 执行非极大值抑制 (NMS)。
     */
    private fun nonMaxSuppression(boxes: List<BBox>, iouThreshold: Float): List<BBox> {
        val sortedBoxes = boxes.sortedByDescending { it.score }
        val selectedBoxes = mutableListOf<BBox>()
        val isActive = BooleanArray(sortedBoxes.size) { true }

        for (i in sortedBoxes.indices) {
            if (!isActive[i]) continue
            val boxA = sortedBoxes[i]
            selectedBoxes.add(boxA)

            for (j in i + 1 until sortedBoxes.size) {
                if (!isActive[j]) continue
                val boxB = sortedBoxes[j]
                
                // 只对同一类别进行 NMS
                if (boxA.classId == boxB.classId) {
                    if (calculateIoU(boxA, boxB) > iouThreshold) {
                        isActive[j] = false
                    }
                }
            }
        }
        return selectedBoxes
    }

    private fun calculateIoU(a: BBox, b: BBox): Float {
        val interX1 = max(a.x1, b.x1)
        val interY1 = max(a.y1, b.y1)
        val interX2 = min(a.x2, b.x2)
        val interY2 = min(a.y2, b.y2)

        val interArea = max(0f, interX2 - interX1) * max(0f, interY2 - interY1)
        val areaA = (a.x2 - a.x1) * (a.y2 - a.y1)
        val areaB = (b.x2 - b.x1) * (b.y2 - b.y1)

        return interArea / (areaA + areaB - interArea + 1e-6f)
    }

    /**
     * 处理分割掩码：Mask 系数与 Protos 矩阵相乘，Sigmoid 激活，裁剪，最后生成 Bitmap。
     */
    private fun processMask(
        maskCoeffs: FloatArray,
        output1Buffer: FloatBuffer,
        x1: Float, y1: Float, x2: Float, y2: Float, // 相对于 inputSize (如 320)
        inputSize: Int,
        origX1: Int, origY1: Int, origX2: Int, origY2: Int, // 恢复到 original 尺寸后的边界框
        originalWidth: Int, originalHeight: Int
    ): Bitmap? {
        val protoChannels = 32
        // 假设 proto 特征图尺寸是输入尺寸的 1/4 (例如 320 -> 80)
        val protoSize = inputSize / 4 
        
        output1Buffer.rewind()

        // 目标是生成原始图像尺寸的掩码。为了性能，我们只在 bounding box 范围内计算掩码。
        val boxWidth = origX2 - origX1
        val boxHeight = origY2 - origY1
        if (boxWidth <= 0 || boxHeight <= 0) return null

        val maskBitmap = Bitmap.createBitmap(originalWidth, originalHeight, Bitmap.Config.ARGB_8888)
        val pixels = IntArray(originalWidth * originalHeight)

        // 遍历原始图像 bounding box 内的每个像素
        for (y in origY1 until origY2) {
            for (x in origX1 until origX2) {
                // 映射原始像素坐标到 proto 特征图坐标
                val protoX = (x.toFloat() / originalWidth * protoSize).toInt().coerceIn(0, protoSize - 1)
                val protoY = (y.toFloat() / originalHeight * protoSize).toInt().coerceIn(0, protoSize - 1)

                var maskValue = 0f
                // 矩阵乘法: maskCoeffs (1x32) * protos (32x1) 针对当前像素点 (protoX, protoY)
                for (c in 0 until protoChannels) {
                    val protoIdx = c * protoSize * protoSize + protoY * protoSize + protoX
                    val protoVal = output1Buffer.get(protoIdx)
                    maskValue += maskCoeffs[c] * protoVal
                }

                // Sigmoid 激活
                val sigmoidValue = 1.0f / (1.0f + exp(-maskValue))

                // 二值化 (阈值设为 0.5)
                if (sigmoidValue > 0.5f) {
                    pixels[y * originalWidth + x] = Color.WHITE // 使用白色填充掩码区域
                }
            }
        }
        
        maskBitmap.setPixels(pixels, 0, originalWidth, 0, 0, originalWidth, originalHeight)
        return maskBitmap
    }
}