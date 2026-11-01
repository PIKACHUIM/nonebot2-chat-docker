"""MyQQBot 容器启动入口。

为什么不用 `nb run`：
    nonebot2 的 wheel 里没有 `nb` 命令入口点（`nb` 来自独立的 nb-cli 包，
    本项目依赖里并没有它），所以直接调用 NoneBot 的 Python API，
    行为更可控、也不依赖 nb-cli 的版本。

启动顺序与 nb-cli 等价：
    1. nonebot.init()            —— 读取 .env / .env.{ENVIRONMENT} 与进程环境变量
    2. register_adapter(QQ)      —— [tool.nonebot.adapters] 只被 nb-cli 消费，这里手动注册
    3. load_from_toml()          —— 读取 pyproject.toml 的 [tool.nonebot.plugins]
    4. nonebot.run()             —— fastapi driver 下等价于 uvicorn.run
"""

from __future__ import annotations

import nonebot
from nonebot.adapters.qq import Adapter as QQAdapter


def main() -> None:
    nonebot.init()

    driver = nonebot.get_driver()
    driver.register_adapter(QQAdapter)

    # 加载 pyproject.toml 中 [tool.nonebot.plugins] 声明的
    # plugin_chatbot.plugins.chat_bridge
    nonebot.load_from_toml("pyproject.toml")

    nonebot.run()


if __name__ == "__main__":
    main()
