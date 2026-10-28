# 视频工具（PyAV + Pillow）：抽帧 / 抽末帧 / 缩放 / 拼帧成片 / 拼接 / 裁剪 / 信息
# 用法：
#   python _video_tools.py info <video>
#   python _video_tools.py lastframe <video> <out.png>
#   python _video_tools.py frames <video> <outdir> <every_n>
#   python _video_tools.py scale <in.mp4> <out.mp4> <倍数>
#   python _video_tools.py fromframes <out.mp4> <fps> <img1> <img2> ...
#   python _video_tools.py concat <out.mp4> <in1.mp4> <in2.mp4> [...]            # 简单拼接
#   python _video_tools.py concatuniform <out.mp4> <fps|auto> <in1.mp4> [...]    # 统一帧率/尺寸后拼接
#   python _video_tools.py trim <in.mp4> <out.mp4> <起点秒> <时长秒>
import sys, os, glob
import av
from av.video.reformatter import VideoReformatter
from PIL import Image


def info(path):
    c = av.open(path)
    s = c.streams.video[0]
    print(f"duration={float(s.duration*s.time_base):.2f}s fps={float(s.average_rate):.1f} size={s.width}x{s.height} frames={s.frames}")


def lastframe(video, out_png):
    c = av.open(video)
    s = c.streams.video[0]
    last = None
    for f in c.decode(s):
        last = f
    if last is None:
        raise SystemExit("no frames")
    img = last.to_image()
    img.save(out_png)
    print("saved", out_png, img.size)


def extract_frames(video, outdir, every_n):
    os.makedirs(outdir, exist_ok=True)
    for old in glob.glob(os.path.join(outdir, "f*.png")):
        os.remove(old)
    c = av.open(video)
    s = c.streams.video[0]
    n = 0
    saved = 0
    for f in c.decode(s):
        if n % every_n == 0:
            saved += 1
            f.to_image().save(os.path.join(outdir, f"f{saved:04d}.png"))
        n += 1
    print(f"frames extracted={saved} from={n} every={every_n} dir={outdir}")


def scale(video, out_path, factor):
    c = av.open(video)
    s = c.streams.video[0]
    fps = float(s.average_rate) or 24.0
    new_w = int(round(s.width * factor / 2) * 2)
    new_h = int(round(s.height * factor / 2) * 2)
    container = av.open(out_path, mode="w")
    stream = container.add_stream("libx264", rate=int(round(fps)))
    stream.width = new_w
    stream.height = new_h
    stream.pix_fmt = "yuv420p"
    stream.options = {"crf": "18"}
    count = 0
    for f in c.decode(s):
        img = f.to_image().resize((new_w, new_h), Image.LANCZOS)
        vf = av.VideoFrame.from_image(img)
        vf.pts = count
        count += 1
        for pkt in stream.encode(vf):
            container.mux(pkt)
    for pkt in stream.encode():
        container.mux(pkt)
    container.close()
    print(f"scale done: {out_path} {new_w}x{new_h} frames={count}")


def fromframes(out_path, fps, images):
    if not images:
        raise SystemExit("no images")
    first = Image.open(images[0])
    w, h = first.size
    first.close()
    container = av.open(out_path, mode="w")
    stream = container.add_stream("libx264", rate=int(fps))
    stream.width = w
    stream.height = h
    stream.pix_fmt = "yuv420p"
    stream.options = {"crf": "18"}
    count = 0
    for p in images:
        img = Image.open(p).convert("RGB")
        if img.size != (w, h):
            img = img.resize((w, h), Image.LANCZOS)
        vf = av.VideoFrame.from_image(img)
        vf.pts = count
        count += 1
        for pkt in stream.encode(vf):
            container.mux(pkt)
    for pkt in stream.encode():
        container.mux(pkt)
    container.close()
    print(f"fromframes done: {out_path} frames={count} fps={fps} size={w}x{h}")


def concat(out_path, inputs):
    if not inputs:
        raise SystemExit("no inputs")
    first = av.open(inputs[0])
    fs = first.streams.video[0]
    width, height = fs.width, fs.height
    fps = float(fs.average_rate) or 24.0
    first.close()

    container = av.open(out_path, mode="w")
    stream = container.add_stream("libx264", rate=int(round(fps)))
    stream.width = width
    stream.height = height
    stream.pix_fmt = "yuv420p"
    stream.options = {"crf": "18"}

    reformatter = VideoReformatter()
    total = 0
    for path in inputs:
        c = av.open(path)
        s = c.streams.video[0]
        if (s.width, s.height) != (width, height):
            for frame in c.decode(s):
                img = frame.to_image().resize((width, height), Image.LANCZOS)
                vf = av.VideoFrame.from_image(img)
                vf.pts = total
                total += 1
                for pkt in stream.encode(vf):
                    container.mux(pkt)
            c.close()
            continue
        for frame in c.decode(s):
            out_frame = reformatter.reformat(frame, format="yuv420p")
            out_frame.pts = total
            total += 1
            for pkt in stream.encode(out_frame):
                container.mux(pkt)
        c.close()

    for pkt in stream.encode():
        container.mux(pkt)
    container.close()
    print(f"concat done: {out_path} frames={total} size={width}x{height} fps={fps:.0f}")


def concat_uniform(out_path, fps_arg, inputs):
    """统一尺寸（取第一段）和帧率后拼接；帧率不同时自动补帧/丢帧。"""
    if not inputs:
        raise SystemExit("no inputs")
    probe = av.open(inputs[0])
    ps = probe.streams.video[0]
    width, height = ps.width, ps.height
    base_fps = float(ps.average_rate) or 24.0
    probe.close()
    if fps_arg and fps_arg.lower() != "auto":
        target_fps = float(fps_arg)
    else:
        target_fps = base_fps
    target_fps = max(1.0, target_fps)

    container = av.open(out_path, mode="w")
    stream = container.add_stream("libx264", rate=int(round(target_fps)))
    stream.width = width
    stream.height = height
    stream.pix_fmt = "yuv420p"
    stream.options = {"crf": "18"}

    total = 0
    for path in inputs:
        c = av.open(path)
        s = c.streams.video[0]
        src_fps = float(s.average_rate) or target_fps
        ratio = target_fps / src_fps
        acc = 0.0
        for frame in c.decode(s):
            acc += ratio
            img = frame.to_image()
            if img.size != (width, height):
                img = img.resize((width, height), Image.LANCZOS)
            while acc >= 1.0:
                acc -= 1.0
                vf = av.VideoFrame.from_image(img)
                vf.pts = total
                total += 1
                for pkt in stream.encode(vf):
                    container.mux(pkt)
        c.close()

    for pkt in stream.encode():
        container.mux(pkt)
    container.close()
    print(f"concatuniform done: {out_path} frames={total} size={width}x{height} fps={target_fps:.0f}")


def crossfade(out_path, fps_arg, duration, inputs):
    """统一尺寸/帧率后做交叉淡化拼接（无音频）。"""
    if len(inputs) < 2:
        raise SystemExit("crossfade needs at least 2 inputs")
    probe = av.open(inputs[0])
    ps = probe.streams.video[0]
    width, height = ps.width, ps.height
    base_fps = float(ps.average_rate) or 24.0
    probe.close()
    if fps_arg and fps_arg.lower() != "auto":
        target_fps = float(fps_arg)
    else:
        target_fps = base_fps
    target_fps = max(1.0, target_fps)
    overlap = max(1, int(round(float(duration) * target_fps)))

    segs = []
    for path in inputs:
        c = av.open(path)
        st = c.streams.video[0]
        frames = []
        for frame in c.decode(st):
            img = frame.to_image()
            if img.size != (width, height):
                img = img.resize((width, height), Image.LANCZOS)
            frames.append(img)
        c.close()
        if frames:
            segs.append(frames)
    if not segs:
        raise SystemExit("crossfade: no frames decoded")

    out = list(segs[0])
    for frames in segs[1:]:
        n = min(overlap, len(frames), len(out))
        for k in range(n):
            alpha = (k + 1) / (n + 1)
            out[-n + k] = Image.blend(out[-n + k], frames[k], alpha)
        out.extend(frames[n:])

    container = av.open(out_path, mode="w")
    stream = container.add_stream("libx264", rate=int(round(target_fps)))
    stream.width = width
    stream.height = height
    stream.pix_fmt = "yuv420p"
    stream.options = {"crf": "18"}
    for i, img in enumerate(out):
        vf = av.VideoFrame.from_image(img)
        vf.pts = i
        for pkt in stream.encode(vf):
            container.mux(pkt)
    for pkt in stream.encode():
        container.mux(pkt)
    container.close()
    print(f"crossfade done: {out_path} frames={len(out)} size={width}x{height} fps={target_fps:.0f} overlap={overlap}")


def trim(video, out_path, start, duration):
    start = max(0.0, float(start))
    duration = float(duration)
    c = av.open(video)
    s = c.streams.video[0]
    fps = float(s.average_rate) or 24.0
    width, height = s.width, s.height
    container = av.open(out_path, mode="w")
    stream = container.add_stream("libx264", rate=int(round(fps)))
    stream.width = width
    stream.height = height
    stream.pix_fmt = "yuv420p"
    stream.options = {"crf": "18"}
    count = 0
    t = 0.0
    for frame in c.decode(s):
        if t < start:
            t += 1.0 / fps
            continue
        if duration > 0 and (t - start) > duration:
            break
        img = frame.to_image()
        vf = av.VideoFrame.from_image(img)
        vf.pts = count
        count += 1
        t += 1.0 / fps
        for pkt in stream.encode(vf):
            container.mux(pkt)
    for pkt in stream.encode():
        container.mux(pkt)
    container.close()
    print(f"trim done: {out_path} frames={count} start={start}s duration={duration}s")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        raise SystemExit("usage: _video_tools.py info|lastframe|frames|scale|fromframes|concat|concatuniform|crossfade|trim ...")
    cmd = sys.argv[1]
    if cmd == "info":
        info(sys.argv[2])
    elif cmd == "lastframe":
        lastframe(sys.argv[2], sys.argv[3])
    elif cmd == "frames":
        extract_frames(sys.argv[2], sys.argv[3], int(sys.argv[4]))
    elif cmd == "scale":
        scale(sys.argv[2], sys.argv[3], float(sys.argv[4]))
    elif cmd == "fromframes":
        fromframes(sys.argv[2], int(sys.argv[3]), sys.argv[4:])
    elif cmd == "concat":
        concat(sys.argv[2], sys.argv[3:])
    elif cmd == "concatuniform":
        concat_uniform(sys.argv[2], sys.argv[3], sys.argv[4:])
    elif cmd == "crossfade":
        crossfade(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:])
    elif cmd == "trim":
        trim(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
    else:
        raise SystemExit(f"unknown command: {cmd}")
