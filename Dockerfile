# syntax=docker/dockerfile:1.7
#
# ComfyUI-only image. One Dockerfile, two profiles chosen by build args:
#
#   modern  (RTX 40xx, driver 590, CUDA 13)
#     --build-arg TORCH_INDEX_URL=https://download.pytorch.org/whl/cu130
#     --build-arg EXTRA_PIP_PACKAGES="sageattention"
#
#   legacy  (GTX 1050 Ti / Pascal sm_61, driver 580, CUDA 12.x)
#     --build-arg TORCH_INDEX_URL=https://download.pytorch.org/whl/cu126
#     --build-arg EXTRA_PIP_PACKAGES=""
#
# The CUDA runtime comes from the PyTorch wheels (nvidia-* pip packages), so the
# base image is plain Ubuntu. Only the driver (libcuda) is injected by the host
# via nvidia-container-toolkit (Docker) or CDI (Podman).
#
# Canonical ComfyUI layout: the app lives in /opt/ComfyUI and all mutable state
# (models, input, output, user, custom_nodes, temp) lives under ONE directory,
# /data, selected with ComfyUI's own --base-directory flag. No symlink games.

FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

# ---- system packages --------------------------------------------------------
# build-essential + python3-dev: Triton / SageAttention / many custom nodes
#   compile small C helpers at runtime.
# libgl1 + libglib2.0-0: required by opencv-python.
# libgoogle-perftools4t64: tcmalloc, loaded by the entrypoint (optional).
ARG APT_EXTRA=""
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-venv python3-dev \
        git curl ca-certificates build-essential \
        libgl1 libglib2.0-0 libgoogle-perftools4t64 \
        ${APT_EXTRA} \
    && rm -rf /var/lib/apt/lists/*

# ---- user -------------------------------------------------------------------
# Ubuntu 24.04 ships an "ubuntu" user at 1000:1000; replace it with "comfy".
# Docker: runs as 1000:1000 -> bind-mounted files belong to host UID 1000.
# Rootless Podman: run with `user: "0:0"`; container root IS the
#   host user, so files also belong to the host user.
ARG COMFY_UID=1000
ARG COMFY_GID=1000
RUN (userdel -r ubuntu 2>/dev/null || true) \
    && (groupdel ubuntu 2>/dev/null || true) \
    && groupadd --gid ${COMFY_GID} comfy \
    && useradd --uid ${COMFY_UID} --gid ${COMFY_GID} --create-home \
               --home-dir /home/comfy --shell /bin/bash comfy \
    && mkdir -p /opt/venv /opt/ComfyUI /data /cache \
    && chown comfy:comfy /opt/venv /opt/ComfyUI /data /cache

# Everything below runs as comfy, so no giant chown layer duplicating torch.
USER comfy
ENV VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:$PATH
RUN python3 -m venv /opt/venv

# ---- PyTorch ----------------------------------------------------------------
ARG TORCH_INDEX_URL=https://download.pytorch.org/whl/cu130
# Pin here if you need to, e.g. "torch==2.8.0 torchvision==0.23.0 torchaudio==2.8.0"
ARG TORCH_PACKAGES="torch torchvision torchaudio"
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir ${TORCH_PACKAGES} --index-url ${TORCH_INDEX_URL} \
    && pip freeze | grep -iE '^(torch|torchvision|torchaudio|triton|pytorch-triton|nvidia-)' \
        > /opt/venv/constraints.txt

# Freeze the torch stack: nothing installed later (build time OR custom nodes /
# ComfyUI-Manager at runtime) may replace it with a different CUDA build.
ENV PIP_CONSTRAINT=/opt/venv/constraints.txt \
    UV_CONSTRAINT=/opt/venv/constraints.txt

# ---- ComfyUI ----------------------------------------------------------------
ARG COMFYUI_REF=v0.42.1
RUN git clone --depth=1 --branch ${COMFYUI_REF} \
        https://github.com/comfyanonymous/ComfyUI.git /opt/ComfyUI \
    && pip install --no-cache-dir -r /opt/ComfyUI/requirements.txt \
    # Newer ComfyUI ships the Manager as a pip package behind --enable-manager.
    # Detect it at build time; the entrypoint adds the flag if the marker exists.
    && if [ -f /opt/ComfyUI/manager_requirements.txt ] \
          && grep -q 'enable-manager' /opt/ComfyUI/comfy/cli_args.py; then \
         pip install --no-cache-dir -r /opt/ComfyUI/manager_requirements.txt \
         && touch /opt/ComfyUI/.manager-builtin; \
       fi

# ---- common custom-node dependencies (pre-baked) ----------------------------
#  opencv-python  Impact-Pack/Subpack, Inspire-Pack, ControlNet-Aux
#  numba          WAS Node Suite
#  piexif         Prompt-Reader-Node, Image-Saver
#  matplotlib     Florence2
#  platformdirs, natsort   Lora-Manager
#  scikit-image   Impact-Pack
#  einops         ControlNet-Aux
ARG PREBAKE_PIP="opencv-python scikit-image numba piexif matplotlib platformdirs natsort einops"
# modern profile: "sageattention". legacy (Pascal): leave empty, nothing works there.
ARG EXTRA_PIP_PACKAGES=""
RUN pip install --no-cache-dir ${PREBAKE_PIP} ${EXTRA_PIP_PACKAGES}

# ---- runtime ----------------------------------------------------------------
ENV HOME=/home/comfy \
    XDG_CACHE_HOME=/cache \
    HF_HOME=/cache/huggingface \
    TORCH_HOME=/cache/torch \
    TRITON_CACHE_DIR=/cache/triton \
    PYTHONUNBUFFERED=1 \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    COMFY_DATA_DIR=/data \
    CLI_ARGS=""

WORKDIR /opt/ComfyUI
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

# /data  -> models/ input/ output/ user/ custom_nodes/ temp/
# /cache -> HuggingFace, torch hub, triton, pip
VOLUME ["/data", "/cache"]
EXPOSE 8188
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
