#!/usr/bin/env bash
# ComfyUI container entrypoint.
#
# Canonical layout: ComfyUI's own --base-directory points at $COMFY_DATA_DIR
# (default /data), which holds models/ input/ output/ user/ custom_nodes/ temp/.
# No symlinks, no chown, no ComfyUI-Manager copying.
#
# Environment knobs:
#   CLI_ARGS                extra ComfyUI flags (word-split), e.g. "--lowvram"
#   COMFY_DATA_DIR          base directory (default /data)
#   COMFY_INSTALL_NODE_DEPS 1 (default) = pip install each custom node's requirements.txt
#                           once per container creation; 0 = skip
#   COMFY_MANAGER           1 (default) = pass --enable-manager if this ComfyUI supports it
#   COMFY_TCMALLOC          1 (default) = LD_PRELOAD tcmalloc if present
set -Eeuo pipefail

DATA="${COMFY_DATA_DIR:-/data}"

# ---- data directories ---------------------------------------------------------
for d in models input output user custom_nodes temp; do
  mkdir -p "$DATA/$d"
done
for d in checkpoints loras vae vae_approx controlnet upscale_models embeddings \
         clip clip_vision text_encoders diffusion_models unet configs; do
  mkdir -p "$DATA/models/$d"
done

# ---- custom node dependencies -------------------------------------------------
# Installed into the (container-local) venv, so they are redone when the
# container is recreated, but not on a plain restart. PIP_CONSTRAINT (set in the
# image) keeps nodes from replacing torch/torchvision/torchaudio/triton.
if [ "${COMFY_INSTALL_NODE_DEPS:-1}" = "1" ] && [ ! -f /tmp/.node-deps-done ]; then
  for req in "$DATA"/custom_nodes/*/requirements.txt; do
    [ -f "$req" ] || continue
    echo "[entrypoint] pip install -r $req"
    pip install --no-cache-dir -r "$req" \
      || echo "[entrypoint] WARNING: dependencies failed for $req (continuing)"
  done
  touch /tmp/.node-deps-done
fi

# ---- optional startup hook ----------------------------------------------------
if [ -f "$DATA/startup.sh" ]; then
  echo "[entrypoint] sourcing $DATA/startup.sh"
  # shellcheck disable=SC1091
  . "$DATA/startup.sh"
fi

# ---- tcmalloc -----------------------------------------------------------------
if [ "${COMFY_TCMALLOC:-1}" = "1" ]; then
  for lib in /usr/lib/x86_64-linux-gnu/libtcmalloc.so.4 /usr/lib/aarch64-linux-gnu/libtcmalloc.so.4; do
    if [ -f "$lib" ]; then
      export LD_PRELOAD="$lib${LD_PRELOAD:+:$LD_PRELOAD}"
      break
    fi
  done
fi

# ---- launch -------------------------------------------------------------------
extra=()
if [ -f /opt/ComfyUI/.manager-builtin ] && [ "${COMFY_MANAGER:-1}" = "1" ]; then
  extra+=(--enable-manager)
fi

echo "[entrypoint] uid=$(id -u) gid=$(id -g) data=$DATA"
# CLI_ARGS is intentionally unquoted so it word-splits into separate flags.
# shellcheck disable=SC2086
exec python -u main.py \
  --listen 0.0.0.0 --port 8188 \
  --base-directory "$DATA" \
  "${extra[@]}" \
  ${CLI_ARGS:-} \
  "$@"
