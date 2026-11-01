# MyQQBot Docker 部署

NoneBot2 + `nonebot-adapter-qq` + `plugin-chatbot` 的容器化部署。

## 目录结构

```
.
├── docker-compose.yml      # 编排：单容器 + 健康检查 + 日志轮转
├── Dockerfile              # python:3.12-slim + espeak-ng + ffmpeg + 插件(git)
├── requirements.txt        # 构建期依赖清单
├── bot.py                  # 容器入口（替代 nb run，原因见文末）
├── pyproject.toml          # 只用于让 nonebot 读取 [tool.nonebot]
├── .env.example            # Compose 层变量 -> 复制为 .env
├── .github/workflows/
│   └── docker.yml          # CI：多架构构建并推送 ghcr.io/<owner>/nonebot-qq
├── env/
│   └── .env.prod           # 业务配置（入库的是占位符版本，部署时直接改）
│                           # 含真密钥的本地副本写 .env.prod.local，已被忽略
└── data/                   # 运行时数据（容器内 /data），自动生成，记得备份
    ├── workspace/          # Agent 工作区，项目记忆在 .agent/memory/
    └── bridge/             # 会话状态 / console-token / voices
```

## 快速开始

```bash
# 1. Compose 层变量
cp .env.example .env

# 2. 业务配置：至少填 QQ_BOTS、AGENT_* 和一个 BRIDGE_OWNER_IDS
${EDITOR:-vim} env/.env.prod

# 3. 预建数据目录并放开权限（Linux 宿主机必做，见「常见问题 1」）
mkdir -p data/workspace data/bridge/voices
sudo chown -R 1000:1000 data

# 4. 拉现成镜像启动（CI 已经把镜像推到 ghcr 了）
docker compose pull && docker compose up -d

#    想本地自己构建就把第 4 步换成：
#    docker compose up -d --build

# 5. 看日志
docker compose logs -f bot
```

启动正常时能看到驱动与适配器初始化、QQ Bot 连接成功，以及 `/chat-agent/` 挂载在 8080。

## 镜像来源

`.github/workflows/docker.yml` 会在 push `main` 或打 `v*` tag 时构建 `linux/amd64` + `linux/arm64`
双架构镜像，推送到 `ghcr.io/pikachuim/nonebot-qq`：

| 触发 | 产出的 tag |
|---|---|
| push 到 `main` | `latest`、`main`、`sha-xxxxxxx` |
| 打 tag `v1.2.3` | `1.2.3`、`1.2`、`latest`、`sha-xxxxxxx` |
| PR | 只构建校验，不推送 |
| 手动 `workflow_dispatch` | 同 `main` |

几个配套动作：

- **首次推送后镜像是 private**。要用 `docker compose pull` 拉，二选一：在仓库 Packages →
  该镜像 → Package settings 里改成 Public；或服务器上先
  `echo <PAT> | docker login ghcr.io -u <用户名> --password-stdin`（PAT 至少勾 `read:packages`）。
- **换 fork 或改镜像名**：改 `.env` 的 `IMAGE_REPO`，同时改 workflow 里 `nonebot-qq` 那段后缀。
  GHCR 的路径必须全小写，workflow 里已经用 `${GITHUB_REPOSITORY_OWNER,,}` 转好了。
- **只跑 x86**：把 workflow 里的 `platforms: linux/amd64,linux/arm64` 改成 `linux/amd64`，
  构建时间能砍一半（arm64 走 QEMU 模拟，最慢的就是 pip 装依赖那层）。
- **升级插件**：改 workflow 里的 `PLUGIN_CHATBOT_REF`，push 后 CI 会出新镜像。

## 密钥不要入库

`env/.env.prod` 现在随仓库发布，内容是纯占位符，部署时直接改它是安全的——但**改完不要 commit**。
本机想留一份含真密钥的副本，用 `env/.env.prod.local`（已被 `.gitignore` 忽略），
再在 compose 的 `env_file` 里追加：

```yaml
    env_file:
      - ./env/.env.prod
      - path: ./env/.env.prod.local
        required: false        # compose >= 2.24
```

`data/`（console-token、会话记录、Agent 记忆）同样被忽略。

提交前自查：

```bash
git status --ignored --short | grep '^!!'                      # 确认 .local / data/ 处于被忽略状态
git grep -nE 'sk-[A-Za-z0-9]{16,}' $(git rev-list --all) -- .  # 历史里不该有真 key
```

如果已经误提交过密钥，删文件不算修复——历史里仍在。要么用
`git filter-repo --invert-paths --path env/.env.prod` 重写历史，要么弃用该仓库重建；
同时务必去模型/QQ 开放平台把泄露的凭据吊销掉。

## 第一次必须做的两件事

1. **填管理员 ID**。白名单全空时谁都用不了。先填一个：
   ```
   BRIDGE_OWNER_IDS=<你的 user_id>
   ```
   不知道自己的 ID 就先启动，然后在允许的群里/私聊里给机器人发一条消息，
   日志里会出现该事件的 `openid` / `user_id`，抄进去重启即可。

2. **想收群里的普通消息（非 @）**，三处都要改：
   - `env/.env.prod` 里 `QQ_BOTS` 的 `intent` 保留 `c2c_group_at_messages: true`
   - QQ 开放平台侧开通对应事件权限
   - 在群里打开机器人设置，把消息接收范围改成 **获取群内全部消息**，
     并把该群的 `group_openid` 加进 `BRIDGE_ALLOWED_GROUPS`

   改完重启，日志里普通群消息应为 `event_type=GROUP_MESSAGE_CREATE`。

## 管理控制台

控制台挂在 `http://127.0.0.1:8080/chat-agent/`，用于角色卡、会话工具开关、
审批、项目记忆、黑话审核、语音库、用量统计。

默认只绑定本机，远程访问走 SSH 隧道：

```bash
ssh -L 8080:127.0.0.1:8080 user@your-server
# 然后本地打开 http://127.0.0.1:8080/chat-agent/
```

令牌在 `data/bridge/console-token`（或你设置的 `BRIDGE_CONSOLE_TOKEN`）。

要真的对外暴露，先设一个长随机令牌，再改 `.env`：

```
BOT_BIND=0.0.0.0
```

并在前面套 nginx/caddy 做 HTTPS + 额外鉴权。裸暴露 8080 等于把机器人后台交出去。

## 常用命令

```bash
docker compose ps                      # 状态与健康
docker compose logs -f --tail=200 bot  # 跟随日志
docker compose restart bot             # 改完 env 后重启（env 变更不会热加载）
docker compose down                    # 停止（data/ 保留）
docker compose build --no-cache        # 彻底重建
```

改 `env/.env.prod` 后必须 `docker compose up -d`（或 `restart`）才生效。

## 升级

**升级插件**（插件不在 PyPI，只能跟 git commit）：

```bash
# 取最新 commit
curl -s https://api.github.com/repos/elysia-best/plugin-chatbot/commits/master \
  | grep -m1 '"sha"' | cut -d'"' -f4
# 把 sha 填进 .env 的 PLUGIN_CHATBOT_REF，然后
docker compose build --pull && docker compose up -d
```

`pyproject.toml` 里 `[tool.uv.sources]` 的 `rev` 也同步改一下，保持本地开发一致。

**升级 NoneBot**：改 `requirements.txt` 里的版本约束，重新 build。

## 常见问题

**1. `PermissionError` / 无法写入 `/data`**
非 root 运行（uid 1000）。Linux 上 Docker 创建的 bind mount 目录属于 `root:root`，
需要 `sudo chown -R 1000:1000 data`。Windows / macOS（Docker Desktop）一般无此问题。
实在不想处理，可在 compose 里给 bot 加 `user: "0:0"`，但会失去非 root 隔离。

**2. 机器人起来了但不回消息**
按顺序排查：`BRIDGE_OWNER_IDS` 是否填；模型的 `AGENT_BASE_URL` 是否带 `/v1`；
群是否开了「获取群内全部消息」；`group_openid` 是否在 `BRIDGE_ALLOWED_GROUPS`；
是否触发了 `BRIDGE_MAX_MESSAGES_PER_MINUTE` 限流。

**3. `QQ_BOTS` 解析失败**
这个变量**必须单行**。`env_file` 不支持多行值，原始项目里那种多行 JSON 会直接报错。
保持 `env/.env.prod` 里压好的一行格式，只改里面的值。

**4. 语音合成无声 / 报 espeak 错误**
镜像里装了 `espeak-ng` 并软链为 `espeak`（pyttsx3 硬编码找这个名字）。
自测：

```bash
docker compose exec bot espeak-ng -v cmn "测试" -w /tmp/t.wav && ls -l /tmp/t.wav
```

**5. 构建太慢 / 拉不动 PyPI**
`.env` 里把 `PIP_INDEX_URL` 换成国内镜像（腾讯云、清华等），再 `docker compose build`。

**6. 换机器迁移**
搬走整个 `data/` 目录 + `env/.env.prod` 即可。`data/bridge` 里是会话映射和用量记录，
`data/workspace/.agent/memory` 是 Agent 的项目记忆。

## 与原项目跑法的差异（为什么不是照搬原 README）

| 原项目 | 这里 | 原因 |
| --- | --- | --- |
| `uv run nb run --env .env.prod` | `python bot.py` | `nonebot2` 的 wheel 没有 `nb` 入口点，`nb` 来自独立的 nb-cli 包，本项目并未依赖它。`bot.py` 直接调 NoneBot API，等价且可控 |
| `plugin-chatbot = { path = "../plugin-chatbot" }` | `pip install "plugin-chatbot @ git+...@<commit>"` | 插件没发布到 PyPI，容器里也不存在同级目录，故钉 commit 从 git 装 |
| 根目录 `.env` + `.env.prod` | 只留 `env/.env.prod` | 根目录 `.env` 会被 Compose 当成变量替换文件，容易打架。NoneBot 的 `DRIVER` / `LOG_LEVEL` 这类非机密项并入 compose 的 `environment`，业务配置统一放 `env/`，原根目录的 `.env*` 可直接删掉 |
| `LOCALSTORE_USE_CWD=true` | 不设置 | 该配置项属于 `nonebot-plugin-localstore`，本项目没装这个插件，设了也没作用。持久化靠 `AGENT_WORKSPACE` / `BRIDGE_STATE_DIR` 两个挂载 |
| 路径写成 `./workspace` | 固定 `/data/workspace` | 容器内路径由 compose `environment` 统一注入，避免相对路径落到镜像层里丢失 |
