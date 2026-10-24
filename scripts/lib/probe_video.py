# 探测视频参数，输出 JSON（供 info.ps1 调用）
# 用法：python probe_video.py <video>
import sys, json
import av

path = sys.argv[1]
c = av.open(path)
s = c.streams.video[0]
print(json.dumps({
    "w": s.width,
    "h": s.height,
    "fps": round(float(s.average_rate), 2) if s.average_rate else 0,
    "dur": round(float(s.duration * s.time_base), 2) if s.duration else 0,
    "frames": s.frames or 0,
    "codec": s.codec_context.name,
    "audio": [a.codec_context.name for a in c.streams if a.type == "audio"],
    "bitrate": c.bit_rate or 0,
}))
