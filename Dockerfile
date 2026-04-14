FROM nvidia/cuda:13.0.1-cudnn-runtime-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    VENV_DIR=/opt/venv \
    COMFY_DIR=/opt/ComfyUI \
    TORCH_INDEX_URL=https://download.pytorch.org/whl/cu130 \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
    HF_HUB_DISABLE_TELEMETRY=1 \
    CM_NETWORK_MODE=personal_cloud \
    CM_SECURITY_LEVEL=weak

SHELL ["/bin/bash", "-lc"]

# add script
COPY scripts/hf-download.sh /opt/bin/hf-download.sh
COPY scripts/civitai-download.sh /opt/bin/civitai-download.sh
COPY scripts/download.sh /opt/bin/download.sh
COPY scripts/st.py /opt/bin/st.py
COPY scripts/entrypoint.sh /opt/bin/entrypoint.sh
COPY scripts/models.manifest /opt/config/models.manifest

RUN chmod +x /opt/bin/hf-download.sh /opt/bin/civitai-download.sh /opt/bin/download.sh
RUN chmod +x /opt/bin/entrypoint.sh
ENV PATH="/opt/bin:${PATH}"

# Pre-fix account db files for odd NAS/container environments
RUN touch /etc/passwd /etc/group && \
    grep -q '^root:' /etc/passwd || echo 'root:x:0:0:root:/root:/bin/bash' >> /etc/passwd && \
    grep -q '^root:' /etc/group || echo 'root:x:0:' >> /etc/group

# 1) System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.12 \
    python3.12-venv \
    python3-pip \
    python3-dev \
    git \
    curl \
    ca-certificates \
    ffmpeg \
    libgl1 \
    libglib2.0-0 \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# 1.5) install micro
RUN curl -fsSL https://getmic.ro | bash && \
    mv micro /usr/local/bin/micro

# 2) Python virtualenv
RUN python3 -m venv ${VENV_DIR} && \
    ${VENV_DIR}/bin/python -m ensurepip --upgrade && \
    ${VENV_DIR}/bin/pip install --upgrade pip && \
    ${VENV_DIR}/bin/pip install "setuptools<82" wheel


# 2.5) install watchdog
RUN ${VENV_DIR}/bin/pip install watchdog

RUN ${VENV_DIR}/bin/pip install "huggingface_hub[cli]"

# 3) Clone ComfyUI
RUN git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git ${COMFY_DIR}

RUN mkdir -p \
    ${COMFY_DIR}/models/checkpoints \
    ${COMFY_DIR}/models/text_encoders \
    ${COMFY_DIR}/models/vae \
    ${COMFY_DIR}/models/loras \
    ${COMFY_DIR}/input \
    ${COMFY_DIR}/output

WORKDIR ${COMFY_DIR}

# 4) Install PyTorch
RUN ${VENV_DIR}/bin/pip install --upgrade \
    torch torchvision torchaudio \
    --index-url ${TORCH_INDEX_URL}

# 5) Install ComfyUI requirements
RUN ${VENV_DIR}/bin/pip install -r ${COMFY_DIR}/requirements.txt
RUN ${VENV_DIR}/bin/python -m pip install -r ${COMFY_DIR}/manager_requirements.txt

# 6) Extra packages you were installing manually
RUN ${VENV_DIR}/bin/pip install \
    sentencepiece \
    accelerate \
    sageattention \
    triton

# 7) Custom nodes
RUN mkdir -p ${COMFY_DIR}/custom_nodes && \
    git clone --depth=1 https://github.com/ltdrdata/ComfyUI-Manager.git ${COMFY_DIR}/custom_nodes/ComfyUI-Manager && \
    git clone --depth=1 https://github.com/rgthree/rgthree-comfy.git ${COMFY_DIR}/custom_nodes/rgthree-comfy && \
    git clone --depth=1 https://github.com/ClownsharkBatwing/RES4LYF.git ${COMFY_DIR}/custom_nodes/RES4LYF && \
    git clone --depth=1 https://github.com/alexopus/ComfyUI-Image-Saver.git ${COMFY_DIR}/custom_nodes/comfyui-image-saver && \
    git clone --depth=1 https://github.com/kijai/ComfyUI-KJNodes.git ${COMFY_DIR}/custom_nodes/comfyui-kjnodes && \
    git clone --depth=1 https://github.com/cubiq/ComfyUI_essentials.git /opt/ComfyUI/custom_nodes/comfyui_essentials && \
    git clone --depth=1 https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git /opt/ComfyUI/custom_nodes/comfyui-videohelpersuite && \
    git clone --depth=1 https://github.com/yolain/ComfyUI-Easy-Use.git /opt/ComfyUI/custom_nodes/comfyui-easy-use && \
    git clone --depth=1 https://github.com/IuvenisSapiens/ComfyUI_Qwen3-VL-Instruct.git /opt/ComfyUI/custom_nodes/ComfyUI_Qwen3-VL-Instruct && \
    git clone --depth=1 https://github.com/kijai/ComfyUI-GIMM-VFI.git ${COMFY_DIR}/custom_nodes/ComfyUI-GIMM-VFI && \
    git clone --depth=1 https://github.com/M1kep/ComfyLiterals.git ${COMFY_DIR}/custom_nodes/ComfyLiterals && \
    git clone --depth=1 https://github.com/boobkake22/ComfyUI-SimpleSwitch.git ${COMFY_DIR}/custom_nodes/ComfyUI-SimpleSwitch && \
    git clone --depth=1 https://github.com/boobkake22/ComfyUI-WanResolutions.git ${COMFY_DIR}/custom_nodes/ComfyUI-WanResolutions && \
    git clone --depth=1 https://github.com/boobkake22/ComfyUI-FilmGrainLTXV.git ${COMFY_DIR}/custom_nodes/ComfyUI-FilmGrainLTXV && \
    git clone --depth=1 https://github.com/VraethrDalkr/ComfyUI-TripleKSampler.git ${COMFY_DIR}/custom_nodes/ComfyUI-TripleKSampler && \
    git clone --depth=1 https://github.com/sipherxyz/comfyui-art-venture.git ${COMFY_DIR}/custom_nodes/comfyui-art-venture && \
    git clone --depth=1 https://github.com/Smirnov75/ComfyUI-mxToolkit.git ${COMFY_DIR}/custom_nodes/ComfyUI-mxToolkit && \
    git clone --depth=1 https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git ${COMFY_DIR}/custom_nodes/ComfyUI-Frame-Interpolation && \
    git clone --depth=1 https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git ${COMFY_DIR}/custom_nodes/ComfyUI-Custom-Scripts && \
    git clone --depth=1 https://github.com/stduhpf/ComfyUI-WanMoeKSampler.git ${COMFY_DIR}/custom_nodes/ComfyUI-WanMoeKSampler

# 8) Install custom node requirements if present
RUN find ${COMFY_DIR}/custom_nodes -maxdepth 2 -name requirements.txt -print0 | \
    xargs -0 -I{} ${VENV_DIR}/bin/pip install -r "{}"

# 9) Manager config
RUN mkdir -p ${COMFY_DIR}/user/__manager && \
    cat > ${COMFY_DIR}/user/__manager/config.ini <<'EOF'
[default]
git_exe =
use_uv = True
use_unified_resolver = False
channel_url = https://raw.githubusercontent.com/ltdrdata/ComfyUI-Manager/main
share_option = all
bypass_ssl = False
file_logging = True
update_policy = stable-comfyui
windows_selector_event_loop_policy = False
model_download_by_agent = False
downgrade_blacklist =
security_level = weak
always_lazy_install = False
network_mode = personal_cloud
db_mode = cache
verbose = False
EOF

# 10) Optional sanity check during build
RUN ${VENV_DIR}/bin/python - <<'PY'
import sys
print("Python:", sys.version)
PY

EXPOSE 8188

ENTRYPOINT ["/opt/bin/entrypoint.sh"]
