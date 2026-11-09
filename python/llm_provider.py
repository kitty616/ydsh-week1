#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
llm_provider.py —— 大模型服务商的统一解析

为什么单独抽出来
----------------
最初只有 nl2sql.py 里一段 if/else，只认 DeepSeek 和通义千问。后来加了
LangChain 版、连通性验证脚本，三处各写一遍解析逻辑，任何一家新增服务商
都要改三个地方，迟早漂移。

这里统一成一张表 + 一个 resolve()，三个脚本共用。要加新服务商只改 PROVIDERS。

设计约定
--------
1. 全部走 OpenAI 兼容协议（/chat/completions），不引入各家私有 SDK。
   代价是少数私有能力（如通义的联网插件）用不了，收益是换一家只改一行配置。
2. 只用环境变量或 .env 取 Key，Key 永远不进代码、不进仓库。
3. 顺序固定，不随机挑：先 DeepSeek，再通义，再其他，保证同一份配置每次跑
   用的是同一个模型，结果可复现。
"""
import os
from dataclasses import dataclass

# 顺序即优先级。改动顺序会影响默认模型，从而影响结果可复现性，慎改。
PROVIDERS = {
    "deepseek": {
        "key_env": "DEEPSEEK_API_KEY",
        "base_url": "https://api.deepseek.com/v1",
        "default_model": "deepseek-chat",
        "console": "https://platform.deepseek.com/api_keys",
        "note": "中文与 SQL 表现好，新账号有赠送额度",
    },
    "dashscope": {
        "key_env": "DASHSCOPE_API_KEY",
        "base_url": "https://dashscope.aliyuncs.com/compatible-mode/v1",
        "default_model": "qwen-plus",
        "console": "https://bailian.console.aliyun.com/",
        "note": "阿里百炼，新用户有免费 token 额度",
    },
    "siliconflow": {
        "key_env": "SILICONFLOW_API_KEY",
        "base_url": "https://api.siliconflow.cn/v1",
        "default_model": "Qwen/Qwen2.5-7B-Instruct",
        "console": "https://cloud.siliconflow.cn/account/ak",
        "note": "有长期免费模型（Qwen2.5-7B），适合零成本验证链路",
    },
    "moonshot": {
        "key_env": "MOONSHOT_API_KEY",
        "base_url": "https://api.moonshot.cn/v1",
        "default_model": "moonshot-v1-8k",
        "console": "https://platform.moonshot.cn/console/api-keys",
        "note": "Kimi，长上下文",
    },
    "zhipu": {
        "key_env": "ZHIPU_API_KEY",
        "base_url": "https://open.bigmodel.cn/api/paas/v4",
        "default_model": "glm-4-flash",
        "console": "https://bigmodel.cn/usercenter/proj-mgmt/apikeys",
        "note": "glm-4-flash 免费；Key 形如 xxx.xxx 两段，别只复制前一段",
    },
}


@dataclass
class Provider:
    name: str
    key: str
    base_url: str
    model: str
    console: str

    @property
    def masked_key(self):
        return self.key[:6] + "*" * 8 + self.key[-4:] if len(self.key) > 12 else "****"


def _get(env, name):
    return env.get(name) or os.environ.get(name)


def resolve(env, forced=None):
    """返回第一个配置了 Key 的 Provider；一个都没有则返回 None

    forced：指定服务商名，此时只看这一家（用于排查，不受优先级影响）
    """
    order = [forced] if forced else list(PROVIDERS)
    for name in order:
        cfg = PROVIDERS.get(name)
        if not cfg:
            raise KeyError(f"未知服务商：{name}，可选：{', '.join(PROVIDERS)}")
        key = _get(env, cfg["key_env"])
        if key:
            model = env.get(f"{name.upper()}_MODEL") or _get(env, f"{name.upper()}_MODEL") or cfg["default_model"]
            return Provider(name=name, key=key, base_url=cfg["base_url"],
                            model=model, console=cfg["console"])
    return None


def configured(env):
    """列出所有已配置 Key 的服务商名（不做调用，只看配置）"""
    return [n for n, c in PROVIDERS.items() if _get(env, c["key_env"])]


def signup_hints():
    """未配置任何 Key 时给用户的申请入口，按优先级"""
    return [(n, c["console"], c["note"]) for n, c in PROVIDERS.items()]


if __name__ == "__main__":
    from nl2sql import load_env

    env = load_env()
    got = configured(env)
    if got:
        p = resolve(env)
        print(f"优先使用：{p.name}  {p.model}  {p.base_url}")
        print(f"已配置的服务商：{', '.join(got)}")
    else:
        print("未配置任何 API Key。可申请入口：")
        for name, url, note in signup_hints():
            print(f"  {name:<12} {url}   # {note}")
