"""Download Qwen-Image 2.1 Turbo GGUFs with resume support via huggingface_hub."""
import os
import sys

os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")
os.environ.setdefault("HF_HUB_ENABLE_HF_TRANSFER", "1")

from huggingface_hub import hf_hub_download

ROOT = r"D:\qwen-image-2.1"
JOBS = [
    ("AtomicChat/Qwen-Image-2.1-Turbo-GGUF", "Qwen-Image-2.1-Turbo-AD-Q6_K.gguf",
     os.path.join(ROOT, "models", "diffusion_models")),
    ("AtomicChat/Qwen-Image-2.1-Turbo-Uncensored-GGUF", "Qwen-Image-2.1-Turbo-Uncensored-Q8_0.gguf",
     os.path.join(ROOT, "models", "text_encoders")),
]

for repo, filename, local_dir in JOBS:
    os.makedirs(local_dir, exist_ok=True)
    target = os.path.join(local_dir, filename)
    # remove truncated partial so the client re-fetches cleanly
    if os.path.exists(target):
        print(f"removing partial {target} ({os.path.getsize(target)} bytes)", flush=True)
        os.remove(target)
    print(f"downloading {repo}/{filename} -> {target}", flush=True)
    path = hf_hub_download(repo_id=repo, filename=filename, local_dir=local_dir,
                           endpoint=os.environ["HF_ENDPOINT"])
    size = os.path.getsize(path)
    print(f"DONE {filename} {size/1024**3:.2f} GB -> {path}", flush=True)
