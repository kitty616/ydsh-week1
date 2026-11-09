#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
llm_ping.py —— 大模型 API 最小化连通性验证

子任务 3 要求「编写 Python 脚本完成一次最小化的大模型调用，验证连通性与返回格式」。
这个脚本只做一件事：发一句最短的话，把返回结构打出来，确认四件事——

  1. Key 有效（不是 401）
  2. 网络可达（不是超时 / 连接被拒）
  3. 返回格式符合 OpenAI 兼容协议（choices[0].message.content 能取到）
  4. 模型名写对了（不是 model not found）

为什么单独写一个脚本而不直接用 nl2sql：
  NL2SQL 的失败原因是复合的——可能是 Key 错、网络断、模型名错、Prompt 太长。
  分层排查要先证明「最底层能通」，否则会在一堆可能性里瞎猜。
  这个脚本 3 秒就能告诉你问题出在哪一层。

用法：
  1) 复制 .env.example 为 .env，填入真实 Key
  2) python python/llm_ping.py
  3) python python/llm_ping.py --model deepseek-chat --prompt "只回复 OK"

退出码：0 = 连通正常；1 = 失败（原因见输出）
"""
import argparse
import os
import sys
import time

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(BASE, "python"))

from nl2sql import load_env  # noqa: E402

PROVIDERS = {
    "deepseek": {
        "key_env": "DEEPSEEK_API_KEY",
        "base_url": "https://api.deepseek.com",
        "default_model": "deepseek-chat",
        "console": "https://platform.deepseek.com/api_keys",
    },
    "dashscope": {
        "key_env": "DASHSCOPE_API_KEY",
        "base_url": "https://dashscope.aliyuncs.com/compatible-mode/v1",
        "default_model": "qwen-plus",
        "console": "https://bailian.console.aliyun.com/",
    },
}


def pick_provider(env, forced=None):
    """选出可用的 provider；forced 指定时只试那一个"""
    order = [forced] if forced else ["deepseek", "dashscope"]
    for name in order:
        cfg = PROVIDERS[name]
        key = env.get(cfg["key_env"]) or os.environ.get(cfg["key_env"])
        if key:
            return name, cfg, key
    return None, None, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--provider", choices=list(PROVIDERS), help="强制指定服务商")
    ap.add_argument("--model", help="覆盖默认模型名")
    ap.add_argument("--prompt", default="请只回复两个字：收到", help="测试用提示词")
    args = ap.parse_args()

    env = load_env()
    name, cfg, key = pick_provider(env, args.provider)

    print("=" * 66)
    print("大模型 API 连通性验证")
    print("=" * 66)

    if not key:
        print("✗ 未找到任何 API Key")
        print()
        print("请按以下步骤配置：")
        print(f"  1) 申请 Key：{PROVIDERS['deepseek']['console']}")
        print("  2) 复制模板：cp .env.example .env")
        print("  3) 在 .env 中填入 DEEPSEEK_API_KEY=sk-xxxx")
        print()
        print("注意：.env 已被 .gitignore 排除，不会进入版本库。")
        print("      不要把 Key 贴进聊天记录或提交到仓库。")
        return 1

    model = args.model or env.get(f"{name.upper()}_MODEL") or cfg["default_model"]
    masked = key[:6] + "*" * 8 + key[-4:] if len(key) > 12 else "****"

    print(f"服务商    : {name}")
    print(f"接口地址  : {cfg['base_url']}")
    print(f"模型      : {model}")
    print(f"Key       : {masked}（长 {len(key)}）")
    print(f"提示词    : {args.prompt}")
    print("-" * 66)

    try:
        from openai import OpenAI
    except ImportError:
        print("✗ 未安装 openai 库，请先执行：pip install openai")
        return 1

    t0 = time.time()
    try:
        client = OpenAI(api_key=key, base_url=cfg["base_url"], timeout=60)
        resp = client.chat.completions.create(
            model=model,
            messages=[{"role": "user", "content": args.prompt}],
            temperature=0,
            max_tokens=50,
        )
    except Exception as e:
        cost = time.time() - t0
        print(f"✗ 调用失败，耗时 {cost:.1f}s")
        print(f"  异常类型：{type(e).__name__}")
        print(f"  异常信息：{str(e)[:300]}")
        print()
        print("排查建议：")
        msg = str(e).lower()
        if "401" in msg or "auth" in msg:
            print("  · 401 / 鉴权失败 → Key 填错、已失效，或复制时带了空格引号")
        elif "404" in msg or "model" in msg:
            print("  · 模型名不存在 → 用 --model 指定该服务商实际提供的模型")
        elif "timeout" in msg or "connect" in msg:
            print("  · 网络不通 → 检查代理设置；本机 github.com 曾出现 443 被阻断")
        elif "quota" in msg or "balance" in msg or "402" in msg:
            print("  · 额度不足 → 账号余额用完，需充值")
        else:
            print("  · 先确认 base_url 与 model 是否属于同一服务商")
        return 1

    cost = time.time() - t0

    # 校验返回结构确实是 OpenAI 兼容格式，而不是某家改过的私有结构
    content = None
    try:
        content = resp.choices[0].message.content
    except (AttributeError, IndexError, KeyError) as e:
        print(f"✗ 返回格式不符合 OpenAI 兼容协议：{type(e).__name__}")
        print(f"  原始返回：{str(resp)[:300]}")
        return 1

    usage = getattr(resp, "usage", None)
    print(f"✓ 调用成功，耗时 {cost:.2f}s")
    print()
    print(f"返回内容  : {content!r}")
    print(f"模型回显  : {getattr(resp, 'model', '(无)')}")
    print(f"结束原因  : {resp.choices[0].finish_reason}")
    if usage:
        print(f"token 用量: prompt={usage.prompt_tokens} "
              f"completion={usage.completion_tokens} total={usage.total_tokens}")
    print()
    print("连通性验证通过。可以继续跑 python/nl2sql.py 了。")
    print("提示：nl2sql.py 会自动读取同一个 .env，无需重复配置。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
