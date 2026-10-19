# comfyui-docker

ComfyUI-only container image. One Dockerfile, two build profiles.

| Profile | GPU | Torch index | Extras | Tag |
|---|---|---|---|---|
| `modern` | RTX 40xx, driver 590, CUDA 13 | `cu130` | `sageattention` | `ghcr.io/<owner>/comfyui-docker:modern` |
| `legacy` | GTX 1050 Ti (Pascal), driver 580 | `cu126` | none | `ghcr.io/<owner>/comfyui-docker:legacy` |

## Layout

- App: `/opt/ComfyUI`, venv: `/opt/venv`
- State: **one** directory, `/data`, passed to ComfyUI as `--base-directory`:
  `models/ input/ output/ user/ custom_nodes/ temp/`
- Caches: `/cache` (HuggingFace, torch hub, Triton, pip)
- Port: `8188`

Bind-mount what you need, either the whole `/data` or each subdirectory.

## Build locally

```bash
# modern
docker build -t comfyui:modern \
  --build-arg TORCH_INDEX_URL=https://download.pytorch.org/whl/cu130 \
  --build-arg EXTRA_PIP_PACKAGES=sageattention .

# legacy
docker build -t comfyui:legacy \
  --build-arg TORCH_INDEX_URL=https://download.pytorch.org/whl/cu126 .
```

Other build args: `COMFYUI_REF` (tag/branch, default `v0.37.0`), `TORCH_PACKAGES`
(pin versions), `PREBAKE_PIP`, `APT_EXTRA`, `COMFY_UID`/`COMFY_GID` (default 1000).

## Runtime env

| Variable | Default | Meaning |
|---|---|---|
| `CLI_ARGS` | empty | extra ComfyUI flags, e.g. `--lowvram --use-sage-attention` |
| `COMFY_INSTALL_NODE_DEPS` | `1` | pip install custom nodes' `requirements.txt` on container creation |
| `COMFY_MANAGER` | `1` | add `--enable-manager` when the ComfyUI version supports it |
| `COMFY_TCMALLOC` | `1` | preload tcmalloc |

`startup.sh` in the data directory, if present, is sourced before launch.

## Users

- **Docker**: container runs as `1000:1000`; bind-mounted files belong to host UID 1000.
- **Rootless Podman**: run with `user: "0:0"`. Container root maps to the invoking host
  user, so files are owned by that user. No `--userns` tricks needed.

## Torch is frozen

`pip freeze` of the torch stack is saved to `/opt/venv/constraints.txt` and exported as
`PIP_CONSTRAINT`/`UV_CONSTRAINT`, so custom nodes and ComfyUI-Manager cannot swap in a
different CUDA build of torch at runtime. If a node genuinely needs a different torch,
rebuild the image instead.

## Notes

- Pascal (1050 Ti) needs a CUDA 12.x torch build; cu128+ wheels may drop sm_61.
  Check the PyTorch release notes before bumping the legacy index.
- Triton and SageAttention do not work on Pascal.
