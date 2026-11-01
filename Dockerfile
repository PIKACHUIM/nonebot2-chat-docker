# syntax=docker/dockerfile:1
#
# MyQQBot 生产镜像
#   NoneBot2 + nonebot-adapter-qq + plugin-chatbot
#
# 说明：
#   * plugin-chatbot 未发布到 PyPI（原项目用 path 依赖 ../plugin-chatbot），
#     因此镜像构建阶段直接从 GitHub 拉取并钉住 commit，保证可复现。
#   * pyttsx3 在 Linux 上靠调用 espeak 命令行合成语音，必须装 espeak-ng。
#   * 镜像内不包含任何 .env 文件，配置全部由 compose 的 env_file 注入。

ARG PYTHON_VERSION=3.12
FROM python:${PYTHON_VERSION}-slim-bookworm

ARG PLUGIN_CHATBOT_REPO=https://github.com/elysia-best/plugin-chatbot
ARG PLUGIN_CHATBOT_REF=b76e29dff6dc3ef8352b9f440aeaff1bdb8e5627
ARG PIP_INDEX_URL=https://pypi.org/simple

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_INDEX_URL=${PIP_INDEX_URL} \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=Asia/Shanghai \
    DEBIAN_FRONTEND=noninteractive

# espeak-ng   : pyttsx3 的离线语音合成后端（含中文 cmn 音色）
# ffmpeg      : 语音/音频转码（QQ 语音消息通常需要 mp3/silk）
# git         : 从 GitHub 安装 plugin-chatbot
# tzdata      : 让 TZ 生效
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        tzdata \
        espeak-ng \
        libespeak-ng1 \
        ffmpeg; \
    # pyttsx3 的 espeak 驱动硬编码查找 `espeak` 命令，Debian 只提供 espeak-ng
    if ! command -v espeak >/dev/null 2>&1; then \
        ln -sf /usr/bin/espeak-ng /usr/bin/espeak; \
    fi; \
    rm -rf /var/lib/apt/lists/*

# 非 root 运行；/data 用于挂载工作区与桥接状态
RUN set -eux; \
    useradd --create-home --uid 1000 --shell /bin/bash bot; \
    mkdir -p /data/workspace /data/bridge/voices; \
    chown -R bot:bot /data /home/bot

WORKDIR /app

# 先装依赖，代码变更不会击穿这一层缓存
COPY --chown=bot:bot requirements.txt ./
RUN set -eux; \
    pip install --no-cache-dir -r requirements.txt; \
    pip install --no-cache-dir \
        "plugin-chatbot @ git+${PLUGIN_CHATBOT_REPO}@${PLUGIN_CHATBOT_REF}"

# pyproject.toml 只用于让 nonebot 读取 [tool.nonebot]（插件/适配器声明）
COPY --chown=bot:bot pyproject.toml bot.py ./

USER bot

EXPOSE 8080

CMD ["python", "-u", "bot.py"]
