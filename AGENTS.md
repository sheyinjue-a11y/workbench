# 助盲智能眼镜重构指南 (AI Agent Context)

## 1. 混合开发架构 (Flutter + Kotlin + C++)
本项目采用端侧协同与混合开发架构，切勿盲目进行全盘语言转换。
* **UI 与业务状态层 (Flutter/Dart)：** 负责界面渲染、状态管理以及与用户的语音交互逻辑。
* **通信与数据流层 (原生 Kotlin/C++)：** 负责底层的蓝牙/Wi-Fi 通信、视频流硬解码以及硬件交互。**【修改禁区：除非明确要求，否则绝对不要修改这部分已稳定运行的代码。】**
* **眼镜端 (ESP32-S3/C++)：** 负责外设控制与数据采集。该部分内容不做修改。

## 2. 当前重构核心目标 (4大功能)
我们正致力于从 `legacy_python_ref` (原 Python 服务端项目) 中提取逻辑，并在手机端重新实现以下四个核心功能：
1. **物品识别与寻找** (参考 `yolomedia.py`, `yoloe_backend.py`)
2. **避障** (参考 `obstacle_avoid.py` 或相关状态机，注意与现有避障逻辑的融合)
3. **盲道导航** (参考 `workflow_blindpath.py`)
4. **过马路导航** (参考 `workflow_crossstreet.py`)


## 3. 跨语言重构法则 (Python -> Dart/Kotlin)
* **精准映射：** 将原 Python 中的统领状态机 (`navigation_master.py`) 改写为 Flutter 的状态管理 (如 Provider/Bloc) 置于 `lib/` 下。涉及高性能计算或底层驱动交互的逻辑，优先考虑补充到现有的 Kotlin 代码中，并通过 MethodChannel 与 Dart 通信。
* **异步非阻塞：** 旧 Python 代码中的阻塞式同步逻辑，在 Dart 中必须使用 Future 或 async/await；在 Kotlin 中必须使用 Coroutines，严禁阻塞主线程。
* **视觉模型调用解耦：** Flutter 端只负责“工作流调度”，把具体的图像帧交给现有的数据流模块处理，获取识别结果（如 Bounding Box 或标签）后再进行 UI 渲染或语音播报。
* **语音播报** 在手机上通过TTS或其他手段实现语音播报，以便于调试

## 4. 前置约束
在提供任何代码前，你必须阅读了 `legacy_python_ref/PROJECT_STRUCTURE.md` 和 `legacy_python_ref/README.md`，建立对旧版状态机流转的心智模型。

## 5.调用lib/models目录下的模型文件前，参考`legacy_python_ref/PROJECT_STRUCTURE.md`确定其功能，同时参考原项目文件中的逻辑考虑其调用方式，必要时可以查看模型dart文件内容