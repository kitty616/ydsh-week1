# -*- coding: utf-8 -*-
"""
hive_client.py —— Streamlit 应用侧的 Hive 访问层

为什么要单独一层，而不是直接用第 3 周 nl2sql.py 里的 run_sql：
  nl2sql.py 的 run_sql 是 `docker exec beeline`——那是「宿主机 + 容器」
  的开发期写法。应用一旦自己进了容器，容器里没有 docker 命令，
  这条链路必然断。所以这里提供两种模式：

    HIVE_CLIENT=pyhive  （容器内默认）直接走 HiveServer2 的 thrift 协议
    HIVE_CLIENT=beeline （宿主机调试）沿用 docker exec beeline

  两种模式返回完全一样的数据结构，上层无感。
"""

from __future__ import annotations

import os
import subprocess
import time

HIVE_HOST = os.environ.get("HIVE_HOST", "localhost")
HIVE_PORT = int(os.environ.get("HIVE_PORT", "10000"))
HIVE_USER = os.environ.get("HIVE_USER", "hive")
HIVE_DB = os.environ.get("HIVE_DB", "default")
CONTAINER = os.environ.get("YDSH_HIVE_CONTAINER", "ydsh-hive-server")
MODE = os.environ.get("HIVE_CLIENT", "pyhive")


# ----------------------------------------------------------------------
# pyhive 模式
# ----------------------------------------------------------------------
def _connect(database: str | None = None):
    from pyhive import hive  # 延迟导入：宿主机没装 pyhive 时也能用 beeline 模式

    return hive.Connection(
        host=HIVE_HOST,
        port=HIVE_PORT,
        username=HIVE_USER,
        database=database or HIVE_DB,
        auth="NONE",
        # 冷启动的 Tez 作业可能跑几分钟，这里不给死超时，
        # 由 Streamlit 侧的 spinner 承担「还在跑」的反馈
    )


def query(sql: str, database: str | None = None):
    """执行查询，返回 (列名列表, 行列表, 耗时秒)。异常向上抛，由调用方展示。"""
    t0 = time.time()
    conn = _connect(database)
    try:
        cur = conn.cursor()
        cur.execute(sql)
        cols = [d[0].split(".")[-1] for d in (cur.description or [])]
        rows = cur.fetchall()
        return cols, rows, round(time.time() - t0, 3)
    finally:
        try:
            conn.close()
        except Exception:
            pass


# ----------------------------------------------------------------------
# beeline 模式（宿主机调试用）
# ----------------------------------------------------------------------
def _query_beeline(sql: str, database: str | None = None):
    t0 = time.time()
    cmd = [
        "docker", "exec", CONTAINER,
        "beeline", "-u", f"jdbc:hive2://localhost:10000/{database or HIVE_DB}",
        "--outputformat=tsv2", "--silent=true", "-e", sql,
    ]
    env = dict(os.environ, MSYS2_ARG_CONV_EXCL="*")
    r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                       errors="replace", env=env, timeout=900)
    if r.returncode != 0:
        raise RuntimeError((r.stderr or r.stdout)[-600:])
    lines = [ln for ln in r.stdout.splitlines()
             if ln.strip() and not ln.startswith(("SLF4J", "[WARN]", "Logging"))
             and ln.strip() != "No such file or directory"]
    if not lines:
        return [], [], round(time.time() - t0, 3)
    cols = lines[0].split("\t")
    rows = [tuple(ln.split("\t")) for ln in lines[1:]]
    return cols, rows, round(time.time() - t0, 3)


# ----------------------------------------------------------------------
# 统一入口
# ----------------------------------------------------------------------
def run(sql: str, database: str | None = None):
    if MODE == "beeline":
        return _query_beeline(sql, database)
    return query(sql, database)


def run_sql_for_nl2sql(sql: str, limit_rows: int = 50):
    """给 nl2sql.ask() 用的兼容实现。

    nl2sql.ask 期望 run_sql 返回 (rows, err)：
      rows[0] 是制表符分隔的表头，其余为数据行；
      出错时 err 是字符串列表。
    这里把结构化结果重新拼成同样的形状，好处是第 3 周的内核代码
    一行都不用改，两个入口共用同一套校验与执行逻辑。
    """
    try:
        cols, rows, _ = run(sql)
    except Exception as e:  # 语法错误、权限、超时都从这里出
        return [], [f"{type(e).__name__}: {str(e)[:300]}"]

    out = ["\t".join(str(c) for c in cols)]
    for r in rows[:limit_rows]:
        out.append("\t".join("" if v is None else str(v) for v in r))
    return out, []


def health() -> tuple[bool, str]:
    """探活：给侧边栏显示数据源状态。"""
    try:
        _, rows, ms = run("SELECT 1")
        return True, f"可用（{ms}s）"
    except Exception as e:
        return False, f"{type(e).__name__}: {str(e)[:120]}"
