# yoloe_backend.py
# coding: utf-8
from typing import List, Dict, Any, Optional, Tuple, Union, TypedDict
import os
import cv2
import time
import numpy as np

# 兼容 YOLOE / YOLO
try:
    from ultralytics import YOLOE as _MODEL
except Exception:
    from ultralytics import YOLO as _MODEL

#设置模型和跟踪器文件路径
DEFAULT_MODEL_PATH = os.getenv("YOLOE_MODEL_PATH", r"C:\Users\Administrator\Desktop\rebuild1002\model\yoloe-11l-seg.pt")
TRACKER_CFG        = os.getenv("YOLO_TRACKER_YAML", "bytetrack.yaml")

class DetectedObject(TypedDict):
    object_id: int
    class_id: int
    class_name: str
    confidence: float
    mask_encoded: bytes
    mask_shape: Tuple[int, int]
    mask_encoding: str
    bbox: Tuple[int, int, int, int]
    center_x: float
    center_y: float
    area_ratio: float
    bottom_y_ratio: float

class NavSegInferInput(TypedDict):
    frame_id: int
    timestamp_ms: int
    width: int
    height: int
    pixel_format: str
    image_bytes: bytes
    roi: Optional[Tuple[int, int, int, int]]
    conf_threshold: Optional[float]
    iou_threshold: Optional[float]
    return_mask: bool
    mask_encoding: str

class NavSegInferOutput(TypedDict):
    frame_id: int
    timestamp_ms: int
    image_width: int
    image_height: int
    num_objects: int
    objects: List[DetectedObject]
    mask_encoding: str
    inference_time_ms: float
    total_time_ms: float
    is_error: bool
    error_message: Optional[str]

def encode_mask_rle(mask: np.ndarray) -> bytes:
    try:
        import pycocotools.mask as mask_util
        rle = mask_util.encode(np.asfortranarray(mask.astype(np.uint8)))
        return rle['counts']
    except Exception:
        return b''

def decode_mask(mask_encoded: bytes, mask_shape: Tuple[int, int], encoding: str) -> np.ndarray:
    try:
        import pycocotools.mask as mask_util
        if encoding == "RLE":
            rle = {"counts": mask_encoded, "size": list(mask_shape)}
            return mask_util.decode(rle)
    except Exception:
        pass
    return np.zeros(mask_shape, dtype=np.uint8)

class YoloEBackend:
    def __init__(self, model_path: Optional[str] = None, device: Optional[Union[str, int]] = None):
        self.model = _MODEL(model_path or DEFAULT_MODEL_PATH)
        self.model.to("cuda")
        self.device = device

    def set_text_classes(self, names: List[str]):
        # YOLOE 文本提示：与你模板一致
        self.model.set_classes(names, self.model.get_text_pe(names))


    def infer(self, infer_input: NavSegInferInput) -> NavSegInferOutput:
        try:
            img = np.frombuffer(infer_input["image_bytes"], dtype=np.uint8).reshape(
                (infer_input["height"], infer_input["width"], 3)
            )
            t0 = time.time()
            r = self.model.track(
                img,
                conf=infer_input.get("conf_threshold", 0.20),
                iou=infer_input.get("iou_threshold", 0.45),
                imgsz=max(img.shape[:2]),
                persist=True, tracker=TRACKER_CFG, verbose=False
            )[0]
            t1 = time.time()
            masks_obj = getattr(r, "masks", None)
            boxes_obj = getattr(r, "boxes", None)
            id2name = r.names if hasattr(r, "names") else {}
            objects: List[DetectedObject] = []
            if masks_obj is not None and getattr(masks_obj, "data", None) is not None and boxes_obj is not None:
                mask_arr = masks_obj.data.cpu().numpy()  # [N, h, w]
                xyxy = boxes_obj.xyxy.cpu().numpy()
                cls  = boxes_obj.cls.cpu().tolist()
                conf = boxes_obj.conf.cpu().tolist()
                tids = boxes_obj.id.int().cpu().tolist() if boxes_obj.id is not None else [None]*len(cls)
                for i in range(len(cls)):
                    bin_mask = (mask_arr[i] > 0.5).astype(np.uint8)
                    if bin_mask.shape[:2] != (img.shape[0], img.shape[1]):
                        bin_mask = cv2.resize(bin_mask, (img.shape[1], img.shape[0]), interpolation=cv2.INTER_NEAREST)
                    mask_encoded = encode_mask_rle(bin_mask) if infer_input.get("mask_encoding", "RLE") == "RLE" else b''
                    x1, y1, x2, y2 = map(int, xyxy[i])
                    area = float(bin_mask.sum())
                    area_ratio = area / float(img.shape[0] * img.shape[1])
                    bottom_y_ratio = float(y2) / img.shape[0]
                    center_x = float((x1 + x2) / 2)
                    center_y = float((y1 + y2) / 2)
                    obj: DetectedObject = {
                        "object_id": int(tids[i]) if tids[i] is not None else i,
                        "class_id": int(cls[i]),
                        "class_name": id2name.get(int(cls[i]), str(cls[i])),
                        "confidence": float(conf[i]),
                        "mask_encoded": mask_encoded,
                        "mask_shape": bin_mask.shape,
                        "mask_encoding": infer_input.get("mask_encoding", "RLE"),
                        "bbox": (x1, y1, x2, y2),
                        "center_x": center_x,
                        "center_y": center_y,
                        "area_ratio": area_ratio,
                        "bottom_y_ratio": bottom_y_ratio
                    }
                    objects.append(obj)
            return {
                "frame_id": infer_input["frame_id"],
                "timestamp_ms": infer_input["timestamp_ms"],
                "image_width": infer_input["width"],
                "image_height": infer_input["height"],
                "num_objects": len(objects),
                "objects": objects,
                "mask_encoding": infer_input.get("mask_encoding", "RLE"),
                "inference_time_ms": (t1-t0)*1000,
                "total_time_ms": (t1-t0)*1000,
                "is_error": False,
                "error_message": None
            }
        except Exception as e:
            return {
                "frame_id": infer_input.get("frame_id", -1),
                "timestamp_ms": infer_input.get("timestamp_ms", 0),
                "image_width": infer_input.get("width", 0),
                "image_height": infer_input.get("height", 0),
                "num_objects": 0,
                "objects": [],
                "mask_encoding": infer_input.get("mask_encoding", "RLE"),
                "inference_time_ms": 0.0,
                "total_time_ms": 0.0,
                "is_error": True,
                "error_message": str(e)
            }
