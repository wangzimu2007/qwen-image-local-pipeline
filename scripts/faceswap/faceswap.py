# -*- coding: utf-8 -*-
"""直连 ONNX 的换脸：SCRFD 检测 + ArcFace 身份 + inswapper_128 交换。
不依赖 insightface 包（Windows 上编译常常失败）。

用法：
  图片：python 换脸.py --src face.png --dst target.png --out out.png
  视频：python 换脸.py --src face.png --dst clip.mp4 --out out.mp4 [--max-faces 1]
"""
import argparse
import os
import subprocess
import sys
import time

import cv2
import numpy as np
import os as _os
import glob as _glob
for _d in [r"D:\audio-tools\gen-venv\Lib\site-packages\torch\lib",
           r"D:\ComfyUI\venv\Lib\site-packages\torch\lib",
           r"D:\ComfyUI-aki-v3.2\python\Lib\site-packages\torch\lib"] + \
          _glob.glob(r"D:\audio-tools\gen-venv\Lib\site-packages\nvidia\*\bin") + \
          _glob.glob(r"D:\ComfyUI-aki-v3.2\python\Lib\site-packages\nvidia\*\bin"):
    try:
        if _os.path.isdir(_d):
            _os.add_dll_directory(_d)
    except Exception:
        pass
import onnxruntime as ort

ROOT = r"D:\qwen-image-2.1\models\faceswap"
DET = os.path.join(ROOT, "insightface-buffalo-l-onnx", "scrfd_10g.onnx")
REC = os.path.join(ROOT, "insightface-buffalo-l-onnx", "arcface_w600k_r50.onnx")
SWAP = os.path.join(ROOT, "inswapper_128.onnx", "inswapper_128.onnx")
ENHANCE = os.path.join(ROOT, "codeformer.onnx")
FFMPEG = r"D:\tools\ffmpeg\bin\ffmpeg.exe"
INPUT_SIZE = int(os.environ.get("FACESWAP_DET_SIZE", "640"))
ARCFACE_TEMPLATE = np.array([
    [38.2946, 51.6963], [73.5318, 51.5014], [56.0252, 71.7366],
    [41.5493, 92.3655], [70.7299, 92.2041]], dtype=np.float32)


def session(path, providers=None):
    so = ort.SessionOptions()
    so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    if providers is None:
        providers = ["CUDAExecutionProvider", "CPUExecutionProvider"] if os.environ.get("FACESWAP_GPU") == "1" else ["CPUExecutionProvider"]
    provs = providers
    try:
        return ort.InferenceSession(path, so, providers=provs)
    except Exception:
        return ort.InferenceSession(path, so, providers=["CPUExecutionProvider"])


def distance2bbox(points, distance):
    x1 = points[:, 0] - distance[:, 0]
    y1 = points[:, 1] - distance[:, 1]
    x2 = points[:, 0] + distance[:, 2]
    y2 = points[:, 1] + distance[:, 3]
    return np.stack([x1, y1, x2, y2], axis=-1)


def distance2kps(points, distance):
    out = []
    for i in range(0, distance.shape[1], 2):
        px = points[:, 0] + distance[:, i]
        py = points[:, 1] + distance[:, i + 1]
        out.append(np.stack([px, py], axis=-1))
    return np.stack(out, axis=1)


def anchor_centers(height, width, stride):
    ac = []
    for y in range(0, height, stride):
        for x in range(0, width, stride):
            ac.append((x, y))
    ac = np.array(ac, dtype=np.float32) + stride // 2
    return np.repeat(ac, 2, axis=0)  # num_anchors = 2


def letterbox(img, size=INPUT_SIZE):
    h, w = img.shape[:2]
    ratio = h / w
    if ratio > 1:
        new_h, new_w = size, int(round(size / ratio))
    else:
        new_w, new_h = size, int(round(size * ratio))
    canvas = np.zeros((size, size, 3), dtype=np.uint8)
    canvas[:new_h, :new_w] = cv2.resize(img, (new_w, new_h))
    return canvas, new_w / w, new_h / h


class FaceEngine:
    def __init__(self):
        self.det = session(DET, ["CPUExecutionProvider"])  # 检测很快，CPU 足够，省显存
        self.rec = session(REC)
        self.swap = session(SWAP)
        self.det_in = self.det.get_inputs()[0].name
        self.rec_in = self.rec.get_inputs()[0].name
        self.swap_inputs = [i.name for i in self.swap.get_inputs()]
        # CodeFormer 增强（懒加载，图片/视频默认开启）
        self.enh = None
        self.enhance = True
        self.enh_alpha = float(os.environ.get("FACESWAP_ENHANCE_ALPHA", "0.75"))

    # ---------- 检测 ----------
    def detect(self, img, conf=0.5, iou=0.4):
        canvas, sx, sy = letterbox(img, INPUT_SIZE)
        blob = cv2.dnn.blobFromImage(canvas, 1.0 / 128.0, (INPUT_SIZE, INPUT_SIZE),
                                     (127.5, 127.5, 127.5), swapRB=True)
        outs = self.det.run(None, {self.det_in: blob})
        # 按输出尺寸归类：scores(N,1) / bbox(N,4) / kps(N,10)
        score_list, bbox_list, kps_list = [], [], []
        for o in outs:
            o = np.asarray(o)
            if o.ndim != 2:
                continue
            if o.shape[1] == 1:
                score_list.append(o)
            elif o.shape[1] == 4:
                bbox_list.append(o)
            elif o.shape[1] == 10:
                kps_list.append(o)
        # 按 N 反推 stride，避免输出顺序假设：stride s → (640/s)^2 * 2
        def _stride_of(n):
            for s in (8, 16, 32):
                if n == (INPUT_SIZE // s) ** 2 * 2:
                    return s
            return None
        score_by_s = {_stride_of(o.shape[0]): o for o in score_list}
        bbox_by_s = {_stride_of(o.shape[0]): o for o in bbox_list}
        kps_by_s = {_stride_of(o.shape[0]): o for o in kps_list}
        order = [8, 16, 32]
        dets, all_kps = [], []
        for idx, stride in enumerate(order):
            if stride not in score_by_s or stride not in bbox_by_s or stride not in kps_by_s:
                continue
            scores = score_by_s[stride].reshape(-1)
            bboxes = bbox_by_s[stride] * stride
            kpss = kps_by_s[stride] * stride
            ac = anchor_centers(INPUT_SIZE, INPUT_SIZE, stride)
            n = min(len(ac), len(scores))
            ac, scores, bboxes, kpss = ac[:n], scores[:n], bboxes[:n], kpss[:n]
            keep = scores >= conf
            if not np.any(keep):
                continue
            ac, scores = ac[keep], scores[keep]
            boxes = distance2bbox(ac, bboxes[keep]) / np.array([sx, sy, sx, sy], dtype=np.float32)
            boxes[:, 0] = np.clip(boxes[:, 0], 0, img.shape[1] - 1)
            boxes[:, 1] = np.clip(boxes[:, 1], 0, img.shape[0] - 1)
            boxes[:, 2] = np.clip(boxes[:, 2], 0, img.shape[1] - 1)
            boxes[:, 3] = np.clip(boxes[:, 3], 0, img.shape[0] - 1)
            kps = distance2kps(ac, kpss[keep]) / np.array([sx, sy], dtype=np.float32)
            dets.extend(boxes.tolist())
            all_kps.extend(kps.tolist())
        if not dets:
            return []
        dets = np.array(dets, dtype=np.float32)
        all_kps = np.array(all_kps, dtype=np.float32).reshape(-1, 5, 2)
        keep_idx = nms(dets, iou)
        return [(dets[i], all_kps[i]) for i in keep_idx]

    # ---------- 身份 ----------
    def embed(self, img, kps):
        M, _ = cv2.estimateAffinePartial2D(kps, ARCFACE_TEMPLATE, method=cv2.LMEDS)
        if M is None:
            return None
        crop = cv2.warpAffine(img, M, (112, 112), borderValue=0)
        blob = cv2.dnn.blobFromImage(crop, 1.0 / 127.5, (112, 112), (127.5, 127.5, 127.5), swapRB=True)
        feat = self.rec.run(None, {self.rec_in: blob})[0].reshape(-1)
        n = np.linalg.norm(feat)
        return feat / n if n > 0 else None

    # ---------- 交换 ----------
    def enhance_face(self, face_bgr):
        """用 CodeFormer 512 提升换脸结果清晰度，再缩回 128。"""
        if not os.path.exists(ENHANCE):
            return face_bgr
        if self.enh is None:
            self.enh = session(ENHANCE)
            self.enh_in = self.enh.get_inputs()[0].name
        rgb = cv2.cvtColor(face_bgr, cv2.COLOR_BGR2RGB)
        big = cv2.resize(rgb, (512, 512), interpolation=cv2.INTER_CUBIC).astype(np.float32) / 255.0
        blob = big.transpose(2, 0, 1)[None]
        try:
            out = self.enh.run(None, {self.enh_in: blob})[0]
        except Exception:
            return face_bgr
        if out.ndim == 4:
            out = out[0].transpose(1, 2, 0)
        out = np.clip(out.astype(np.float32) * 255.0, 0, 255)
        back = cv2.resize(out, (face_bgr.shape[1], face_bgr.shape[0]), interpolation=cv2.INTER_LANCZOS4)
        a = max(0.0, min(1.0, self.enh_alpha))
        merged = back * a + rgb.astype(np.float32) * (1.0 - a)
        return cv2.cvtColor(np.clip(merged, 0, 255).astype(np.uint8), cv2.COLOR_RGB2BGR)

    def swap_face(self, img, kps, emb):
        tpl = ARCFACE_TEMPLATE * (128.0 / 112.0)
        M, _ = cv2.estimateAffinePartial2D(kps, tpl, method=cv2.LMEDS)
        if M is None:
            return None
        crop = cv2.warpAffine(img, M, (128, 128), borderValue=0)
        # inswapper 的 target 期望 0~1 浮点（BGR，不换通道），输出也是 0~1
        blob = crop.astype(np.float32).transpose(2, 0, 1)[None] / 255.0
        feed = {}
        for name in self.swap_inputs:
            if "target" in name.lower() or "image" in name.lower():
                feed[name] = blob
            else:
                feed[name] = emb.reshape(1, -1).astype(np.float32)
        out = self.swap.run(None, feed)[0]
        if out.ndim == 4:
            out = out[0].transpose(1, 2, 0)
        out = np.clip(out.astype(np.float32) * 255.0, 0, 255).astype(np.uint8)
        if getattr(self, "enhance", True):
            out = self.enhance_face(out)
        # 反变换贴回
        inv = cv2.invertAffineTransform(M)
        warped = cv2.warpAffine(out, inv, (img.shape[1], img.shape[0]))
        mask = np.zeros((128, 128), dtype=np.float32)
        mask[8:120, 8:120] = 1.0
        mask = cv2.GaussianBlur(mask, (13, 13), 0)
        mask_full = cv2.warpAffine(mask, inv, (img.shape[1], img.shape[0]))[:, :, None]
        return warped.astype(np.float32) * mask_full + img.astype(np.float32) * (1.0 - mask_full)


def nms(boxes, thresh):
    x1, y1, x2, y2 = boxes[:, 0], boxes[:, 1], boxes[:, 2], boxes[:, 3]
    areas = (x2 - x1) * (y2 - y1)
    order = areas.argsort()[::-1]
    keep = []
    while order.size > 0:
        i = order[0]
        keep.append(i)
        xx1 = np.maximum(x1[i], x1[order[1:]])
        yy1 = np.maximum(y1[i], y1[order[1:]])
        xx2 = np.minimum(x2[i], x2[order[1:]])
        yy2 = np.minimum(y2[i], y2[order[1:]])
        inter = np.maximum(0.0, xx2 - xx1) * np.maximum(0.0, yy2 - yy1)
        iou = inter / (areas[i] + areas[order[1:]] - inter + 1e-6)
        order = order[1:][iou <= thresh]
    return keep


def make_embedding(engine, src_path):
    img = imread_unicode(src_path)
    faces = engine.detect(img, conf=0.35)
    if not faces:
        raise SystemExit("源图没检测到人脸：" + src_path)
    box, kps = max(faces, key=lambda f: (f[0][2] - f[0][0]) * (f[0][3] - f[0][1]))
    emb = engine.embed(img, kps)
    if emb is None:
        raise SystemExit("源脸特征提取失败")
    print(f"源脸：{src_path} 框 {np.round(box).astype(int).tolist()}")
    return emb


def imread_unicode(path):
    data = np.fromfile(path, dtype=np.uint8)
    img = cv2.imdecode(data, cv2.IMREAD_COLOR)
    if img is None:
        raise SystemExit("读不到图片：" + path)
    return img


def imwrite_unicode(path, img):
    ext = os.path.splitext(path)[1] or ".png"
    ok, buf = cv2.imencode(ext, img)
    if not ok:
        raise SystemExit("编码失败：" + path)
    buf.tofile(path)


def process_image(engine, emb, src_img, out_path, max_faces=1):
    faces = engine.detect(src_img, conf=0.4)
    faces = sorted(faces, key=lambda f: (f[0][2] - f[0][0]) * (f[0][3] - f[0][1]), reverse=True)[:max_faces]
    if not faces:
        raise SystemExit("目标图没检测到人脸")
    result = src_img.astype(np.float32)
    for box, kps in faces:
        swapped = engine.swap_face(result.astype(np.uint8), kps, emb)
        if swapped is not None:
            result = swapped
    result = np.clip(result, 0, 255).astype(np.uint8)
    imwrite_unicode(out_path, result)
    print(f"图片换脸完成：{out_path}（换 {len(faces)} 张脸）")
    return out_path


def process_video(engine, emb, src_path, out_path, max_faces=1, det_every=12):
    cap = cv2.VideoCapture(src_path)
    if not cap.isOpened():
        raise SystemExit("打不开视频：" + src_path)
    fps = cap.get(cv2.CAP_PROP_FPS) or 24
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    print(f"视频 {w}x{h} @ {fps:.2f}fps，共 {total} 帧")
    tmp = os.path.splitext(out_path)[0] + ".noaudio.mp4"
    vw = cv2.VideoWriter(tmp, cv2.VideoWriter_fourcc(*"mp4v"), fps, (w, h))
    n = 0
    t0 = time.time()
    prev_gray = None
    last_kps = None
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        need_det = (n % max(1, det_every) == 0) or (last_kps is None) or (prev_gray is None)
        kps_now = None
        if not need_det:
            pts = last_kps.reshape(-1, 1, 2).astype(np.float32)
            new_pts, st, _ = cv2.calcOpticalFlowPyrLK(prev_gray, gray, pts, None,
                                                      winSize=(21, 21), maxLevel=3)
            if st is not None and int(st.sum()) == 5:
                cand = new_pts.reshape(-1, 2)
                if float(np.max(np.linalg.norm(cand - last_kps.reshape(-1, 2), axis=1))) < 60:
                    kps_now = cand
        if kps_now is None:
            faces = engine.detect(frame, conf=0.4)
            faces = sorted(faces, key=lambda f: (f[0][2] - f[0][0]) * (f[0][3] - f[0][1]), reverse=True)[:max_faces]
            if faces:
                kps_now = faces[0][1]
        last_kps = kps_now
        prev_gray = gray
        out = frame
        if kps_now is not None:
            swapped = engine.swap_face(out, kps_now, emb)
            if swapped is not None:
                out = np.clip(swapped, 0, 255).astype(np.uint8)
        vw.write(out)
        n += 1
        if n % 24 == 0:
            print(f"  {n}/{total} 帧  {n / max(time.time() - t0, 1e-6):.1f} fps")
    cap.release()
    vw.release()
    # 合并原音轨
    cmd = [FFMPEG, "-y", "-i", tmp, "-i", src_path, "-map", "0:v:0", "-map", "1:a:0?",
           "-c:v", "libx264", "-crf", "18", "-preset", "medium", "-c:a", "aac", "-b:a", "192k",
           "-shortest", out_path]
    subprocess.run(cmd, capture_output=True)
    try:
        os.remove(tmp)
    except OSError:
        pass
    if not os.path.exists(out_path):
        os.replace(tmp, out_path)
    print(f"视频换脸完成：{out_path}（{n} 帧，{time.time() - t0:.1f} 秒）")
    return out_path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, help="提供脸的照片")
    ap.add_argument("--dst", required=True, help="要换脸的目标图/视频")
    ap.add_argument("--out", required=True)
    ap.add_argument("--max-faces", type=int, default=1)
    ap.add_argument("--det-every", type=int, default=12)
    ap.add_argument("--no-enhance", action="store_true", help="关闭 CodeFormer 增强")
    a = ap.parse_args()
    engine = FaceEngine()
    engine.enhance = not a.no_enhance
    emb = make_embedding(engine, a.src)
    ext = os.path.splitext(a.dst)[1].lower()
    if ext in (".mp4", ".mov", ".avi", ".mkv"):
        process_video(engine, emb, a.dst, a.out, a.max_faces, a.det_every)
    else:
        img = imread_unicode(a.dst)
        process_image(engine, emb, img, a.out, a.max_faces)


if __name__ == "__main__":
    main()
