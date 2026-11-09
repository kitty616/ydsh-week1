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
  python python/llm_ping.py                  # 用优先级最高的已配置服务商
  python python/llm_ping.py --all            # 逐个探测所有已配置的服务商
  python python/llm_ping.py --provider zhipu --model glm-4-flash
  python python/llm_ping.py --prompt "只回复 OK"

退出码：0 = 至少一个服务商连通；1 = 全部失败或未配置
"""
import argparse
import sys
import os
import time

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(BASE, "python"))

from llm_provider import PROVIDERS, configured, resolve, signup_hints  # noqa: E402
from nl2sql import load_env  # noqa: E402


def list_models(p):
    """用 OpenAI 兼容的 GET /models 拉该服务商的模型列表

    为什么需要它：各家的控制台叫法（如体验中心显示「GLM-5.3」）和 API 里真正
    要填的 model 参数常常不是一个字符串，靠猜只会反复吃 404。能拉到就直接看。

    返回 (模型 id 列表 or None, 错误说明 or None)。不是所有服务商都实现这个端点，
    拉不到不算失败，只是少一条线索。
    """
    try:
        from openai import OpenAI
    except ImportError:
        return None, "未安装 openai 库"
    try:
        client = OpenAI(api_key=p.key, base_url=p.base_url, timeout=30)
        return [m.id for m in client.models.list().data], None
    except Exception as e:
        return None, f"{type(e).__name__}: {str(e)[:160]}"


def ping(p, prompt, model=None, quiet=False):
    """对单个 Provider 发一次最小调用，返回 (成功?, 耗时, 说明)"""
    model = model or p.model
    if not quiet:
        print(f"服务商    : {p.name}")
        print(f"接口地址  : {p.base_url}")
        print(f"模型      : {model}")
        print(f"Key       : {p.masked_key}（长 {len(p.key)}）")
        print(f"提示词    : {prompt}")
        print("-" * 66)

    try:
        from openai import OpenAI
    except ImportError:
        return False, 0, "未安装 openai 库，请先执行：pip install openai"

    t0 = time.time()
    try:
        client = OpenAI(api_key=p.key, base_url=p.base_url, timeout=60)
        resp = client.chat.completions.create(
            model=model,
            messages=[{"role": "user", "content": prompt}],
            temperature=0,
            max_tokens=50,
        )
    except Exception as e:
        cost = time.time() - t0
        msg = str(e)
        if not quiet:
            print(f"✗ 调用失败，耗时 {cost:.1f}s")
            print(f"  异常类型：{type(e).__name__}")
            print(f"  异常信息：{msg[:300]}")
            print()
            print("排查建议：")
            low = msg.lower()
            if "401" in low or "auth" in low:
                print("  · 401 / 鉴权失败 → Key 填错、已失效，或复制时带了空格引号")
            elif "404" in low or "model" in low:
                print("  · 模型名不存在 → 用 --model 指定该服务商实际提供的模型")
                ids, err = list_models(p)
                if ids:
                    print(f"  · 该服务商实际可用模型 {len(ids)} 个，前 15 个：")
                    for mid in ids[:15]:
                        print(f"      {mid}")
                elif err:
                    print(f"  · GET /models 不可用（{err[:70]}），请到控制台页查模型名")
            elif "timeout" in low or "connect" in low:
                print("  · 网络不通 → 检查代理设置；本机 github.com 曾出现 443 被阻断")
            elif "quota" in low or "balance" in low or "402" in low or "429" in low:
                print("  · 额度不足 / 限流 → 账号余额用完或触发频率限制，需充值或降低频率")
            else:
                print("  · 先确认 base_url 与 model 是否属于同一服务商")
        return False, round(cost, 2), f"{type(e).__name__}: {msg[:120]}"

    cost = time.time() - t0

    # 校验返回结构确实是 OpenAI 兼容格式，而不是某家改过的私有结构
    try:
        content = resp.choices[0].message.content
    except (AttributeError, IndexError, KeyError) as e:
        return False, round(cost, 2), f"返回格式不符合 OpenAI 兼容协议：{type(e).__name__}"

    usage = getattr(resp, "usage", None)
    if not quiet:
        print(f"✓ 调用成功，耗时 {cost:.2f}s")
        print()
        print(f"返回内容  : {content!r}")
        print(f"模型回显  : {getattr(resp, 'model', '(无)')}")
        print(f"结束原因  : {resp.choices[0].finish_reason}")
        if usage:
            print(f"token 用量: prompt={usage.prompt_tokens} "
                  f"completion={usage.completion_tokens} total={usage.total_tokens}")
    return True, round(cost, 2), (content or "")[:40]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--provider", choices=list(PROVIDERS), help="强制指定服务商")
    ap.add_argument("--model", help="覆盖默认模型名")
    ap.add_argument("--prompt", default="请只回复两个字：收到", help="测试用提示词")
    ap.add_argument("--all", action="store_true", help="遍历所有已配置的服务商")
    ap.add_argument("--list-models", action="store_true",
                    help="拉取该服务商实际可用的模型 id（填 .env 前先跑这个）")
    args = ap.parse_args()

    env = load_env()

    print("=" * 66)
    print("大模型 API 连通性验证")
    print("=" * 66)

    # --list-models：先把真实模型 id 查出来，避免拿控制台显示名去猜 model 参数
    if args.list_models:
        p = resolve(env, args.provider)
        if p is None:
            print("✗ 未找到任何 API Key，先填 .env")
            return 1
        print(f"服务商    : {p.name}")
        print(f"接口地址  : {p.base_url}")
        print(f"Key       : {p.masked_key}")
        print("-" * 66)
        ids, err = list_models(p)
        if ids:
            print(f"可用模型 {len(ids)} 个（把要用的那个填进 .env 的 *_MODEL）：")
            for mid in ids:
                print(f"  {mid}")
            return 0
        print(f"✗ 拉取失败：{err}")
        print("  该服务商可能没实现 GET /models，请到控制台页面查看模型名，")
        print("  再用 --model 直接试：python python/llm_ping.py --model <模型名>")
        return 1

    # --all：逐家探测，做成对照表
    if args.all:
        names = configured(env)
        if not names:
            print("✗ 没有任何已配置的 API Key，无法遍历。")
            _print_signup()
            return 1
        results = []
        for n in names:
            p = resolve(env, forced=n)
            ok, cost, note = ping(p, args.prompt, quiet=True)
            results.append((n, p.model, ok, cost, note))
            print(f"{'✓' if ok else '✗'} {n:<12} {p.model:<28} {cost:>6.2f}s  {note}")
        print("-" * 66)
        ok_cnt = sum(1 for r in results if r[2])
        print(f"连通 {ok_cnt}/{len(results)}")
        return 0 if ok_cnt else 1

    p = resolve(env, args.provider)

    if p is None:
        print("✗ 未找到任何 API Key")
        print()
        _print_signup()
        return 1

    ok, _, _ = ping(p, args.prompt, model=args.model)
    if not ok:
        return 1

    print()
    print("连通性验证通过。可以继续跑：")
    print("  python python/nl2sql.py --batch          # 手写 SDK 版")
    print("  python python/nl2sql_chain.py --batch    # LangChain 编排版")
    print("提示：两个脚本读取同一个 .env，无需重复配置。")
    return 0


def _print_signup():
    print("请按以下步骤配置（任选一家即可，第 3、5 家有长期免费模型）：")
    for i, (name, url, note) in enumerate(signup_hints(), 1):
        print(f"  {i}) {name:<12} {url}")
        print(f"      {note}")
    print()
    print("  然后：cp .env.example .env，把 Key 填进去")
    print()
    print("注意：.env 已被 .gitignore 排除，不会进入版本库。")
    print("      不要把 Key 贴进聊天记录或提交到仓库。")


if __name__ == "__main__":
    sys.exit(main())
