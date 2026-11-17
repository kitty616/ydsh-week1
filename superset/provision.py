#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
Superset 资产编排（幂等）：数据源 -> 数据集 -> 图表 -> 仪表板

为什么走容器内 ORM 而不是 /api/v1 的 REST 接口：

  1. 写接口（POST/PUT）要求 CSRF token，脚本用 Bearer 令牌会直接 400
     "The CSRF token is missing"；
  2. 补上 Cookie + CSRF 之后，GET 列表接口又因为两种凭证并存返回 422；
  3. 4.1 版本建 Hive 数据源时会探测 SHOW CATALOGS，apache/hive:4.0.0 不认，
     返回 422 "Database could not be created"。

  在容器内直接用 Superset 自己的 ORM 写库，绕开整条认证/序列化链路，
  同时也避开了 catalog 探测（连接参数由我们直接给出）。

跑法（必须在容器内，且要关掉 Git Bash 的路径转换）：
  MSYS2_ARG_CONV_EXCL='*' docker exec ydsh-superset \
      python /app/pythonpath/provision.py
"""
from __future__ import annotations

import json
import logging
import os
import sys

from superset.app import create_app

app = create_app()

logging.basicConfig(level=logging.INFO, format="%(message)s")
log = logging.getLogger("provision")

# ---------------------------------------------------------------- 常量

# 三个数据源分别对应数仓四层里的不同用途：
#   Hive       —— ADS 结果表源头（重计算，走 MapReduce/Tez）
#   MySQL      —— 服务层小表（结果已物化，秒级响应）
#   ClickHouse —— 加速层（明细/聚合大表，毫秒级）
DATABASES = [
    {
        "name": "Hive 数仓 (ydsh_ads)",
        "uri": "hive://hive@hive-server:10000/ydsh_ads",
        "extra": {"metadata_params": {}, "engine_params": {}, "metadata_cache_timeout": {}},
    },
    {
        "name": "MySQL 服务层 (ydsh_ads)",
        "uri": (
            f"mysql+pymysql://{os.environ.get('MYSQL_USER', 'root')}:"
            f"{os.environ.get('MYSQL_ROOT_PASSWORD', '')}"
            f"@mysql:3306/ydsh_ads?charset=utf8mb4"
        ),
        "extra": {},
    },
    {
        "name": "ClickHouse 加速层 (ydsh_ads)",
        "uri": (
            f"clickhousedb+connect://{os.environ.get('CLICKHOUSE_USER', 'default')}:"
            f"{os.environ.get('CLICKHOUSE_PASSWORD', '')}"
            f"@clickhouse:8123/ydsh_ads"
        ),
        "extra": {},
    },
]

# 数据集：(数据库名, schema, 表名)
DATASETS = [
    ("Hive 数仓 (ydsh_ads)", "ydsh_ads", "ads_sales_daily_report"),
    ("Hive 数仓 (ydsh_ads)", "ydsh_ads", "ads_category_topn"),
    ("Hive 数仓 (ydsh_ads)", "ydsh_ads", "ads_store_rank"),
    ("Hive 数仓 (ydsh_ads)", "ydsh_ads", "ads_user_segment"),
    ("MySQL 服务层 (ydsh_ads)", "ydsh_ads", "pay_type"),
    ("MySQL 服务层 (ydsh_ads)", "ydsh_ads", "sales_daily"),
    ("MySQL 服务层 (ydsh_ads)", "ydsh_ads", "monthly"),
    ("MySQL 服务层 (ydsh_ads)", "ydsh_ads", "region"),
    ("ClickHouse 加速层 (ydsh_ads)", "ydsh_ads", "trade_monthly"),
    ("ClickHouse 加速层 (ydsh_ads)", "ydsh_ads", "sales_daily"),
]

DASHBOARD_SLUG = "ydsh-week4-ops"
DASHBOARD_TITLE = "运营驾驶舱 · 易达生活（第 4 周）"


# ---------------------------------------------------------------- 工具

def adhoc_metric(column: str, aggregate: str = "SUM", label: str | None = None,
                 col_type: str = "DOUBLE") -> dict:
    """构造 Superset 的"临时指标"结构。

    不用数据集里的实体指标（metrics），因为实体指标要预先写进
    SqlaTable.metrics 的 JSON 列，改一次就得重跑一次；临时指标跟着
    图表参数走，幂等脚本里更省事。
    """
    label = label or f"{aggregate}({column})"
    return {
        "expressionType": "SIMPLE",
        "column": {
            "column_name": column,
            "id": abs(hash(column)) % 100000,
            "type": col_type,
            "type_generic": None,
            "is_dttm": col_type in ("DATE", "DATETIME", "TIMESTAMP"),
            "filterable": True,
            "groupby": True,
            "optionName": f"column_{column}",
            "verbose_name": None,
            "python_date_format": None,
            "expression": None,
        },
        "aggregate": aggregate,
        "sqlExpression": None,
        "label": label,
        "hasCustomLabel": True,
        "optionName": f"metric_{aggregate.lower()}_{column}",
    }


def get_database(db, spec: dict):
    from superset.models.core import Database

    obj = (
        db.session.query(Database)
        .filter(Database.database_name == spec["name"])
        .one_or_none()
    )
    if obj is None:
        obj = Database(
            database_name=spec["name"],
            sqlalchemy_uri=spec["uri"],
            expose_in_sqllab=True,
            allow_run_async=False,
            allow_ctas=False,
            allow_cvas=False,
            allow_file_upload=False,
        )
        db.session.add(obj)
        db.session.commit()
        log.info("  [+] 数据源 %s", spec["name"])
    else:
        obj.sqlalchemy_uri = spec["uri"]
        db.session.commit()
        log.info("  [=] 数据源 %s（已存在）", spec["name"])
    obj.extra = json.dumps(spec.get("extra") or {})
    db.session.commit()
    return obj


def get_dataset(db, database, schema: str, table: str):
    from superset.connectors.sqla.models import SqlaTable

    obj = (
        db.session.query(SqlaTable)
        .filter(
            SqlaTable.table_name == table,
            SqlaTable.schema == schema,
            SqlaTable.database_id == database.id,
        )
        .one_or_none()
    )
    if obj is None:
        obj = SqlaTable(table_name=table, schema=schema, database=database)
        db.session.add(obj)
        db.session.commit()
        log.info("  [+] 数据集 %s.%s", schema, table)
    else:
        log.info("  [=] 数据集 %s.%s（已存在）", schema, table)

    # fetch_metadata 是必须的：它把表结构写进 table_columns。
    # 不调用的话数据集在图表编辑器里"一列都没有"，选不出维度和指标。
    try:
        obj.fetch_metadata()
        db.session.commit()
        log.info("      列数 %d", len(obj.columns))
    except Exception as exc:  # noqa: BLE001
        db.session.rollback()
        log.warning("      ! 元数据抓取失败：%s", exc)
    return obj


def upsert_chart(db, name: str, viz_type: str, dataset, params: dict, description: str = ""):
    from superset.models.slice import Slice

    params = dict(params)
    params["datasource"] = f"{dataset.id}__table"
    params["viz_type"] = viz_type
    payload = json.dumps(params, ensure_ascii=False)

    obj = db.session.query(Slice).filter(Slice.slice_name == name).one_or_none()
    if obj is None:
        obj = Slice(
            slice_name=name,
            viz_type=viz_type,
            datasource_id=dataset.id,
            datasource_type="table",
            datasource_name=f"{dataset.schema}.{dataset.table_name}",
            params=payload,
            description=description,
        )
        db.session.add(obj)
    else:
        obj.viz_type = viz_type
        obj.datasource_id = dataset.id
        obj.datasource_type = "table"
        obj.datasource_name = f"{dataset.schema}.{dataset.table_name}"
        obj.params = payload
        obj.description = description

    # perm / schema_perm 决定"谁能看这张图"，V2 权限模型下留空会导致
    # 图表在仪表板上报 403，必须显式写。
    obj.perm = f"[{dataset.database.database_name}].[{dataset.table_name}](id:{dataset.id})"
    obj.schema_perm = f"[{dataset.database.database_name}].[{dataset.schema}]"
    db.session.commit()
    log.info("  [+] 图表 #%s %s (%s)", obj.id, name, viz_type)
    return obj


# ---------------------------------------------------------------- 主流程

def build():
    from superset import db
    from superset.models.dashboard import Dashboard
    from superset.models.slice import Slice

    log.info("== 1. 数据源 ==")
    dbs = {spec["name"]: get_database(db, spec) for spec in DATABASES}

    log.info("== 2. 数据集 ==")
    ds = {}
    for db_name, schema, table in DATASETS:
        ds[(db_name, table)] = get_dataset(db, dbs[db_name], schema, table)

    hive = "Hive 数仓 (ydsh_ads)"
    my = "MySQL 服务层 (ydsh_ads)"
    ck = "ClickHouse 加速层 (ydsh_ads)"

    log.info("== 3. 图表 ==")
    charts = []

    # 3.1 日 GMV 趋势（ClickHouse 时间轴，月粒度聚合）
    #     放 ClickHouse 而不是 Hive：CK 的 dt 是真 Date 类型，时间轴天然可用，
    #     顺带验证第三个数据源连通性；同一条 SQL 在 Hive 上要 10s+，这里 30ms。
    charts.append(upsert_chart(
        db, "① 日 GMV 趋势（月度聚合）", "echarts_timeseries_line",
        ds[(ck, "sales_daily")],
        {
            "granularity_sqla": "dt",
            "time_grain_sqla": "P1M",
            "time_range": "2024-01-01 : 2024-12-31",
            "metrics": [adhoc_metric("gmv", "SUM", "GMV")],
            "groupby": [],
            "adhoc_filters": [],
            "row_limit": 10000,
            "x_axis": "dt",
            "x_axis_title": "月份",
            "y_axis_title": "GMV（元）",
            "x_axis_time_format": "%m月",
            "xAxisLabelRotation": -45,
            "seriesType": "line",
            "smooth": True,
            "show_legend": True,
            "markerEnabled": True,
            "rich_tooltip": True,
            "y_axis_format": ",.0f",
        },
        "ClickHouse 上按自然月聚合全年 366 天日销，用于观察淡旺季。",
    ))

    # 3.2 月度环比（柱状 + 折线双轴；分类轴强制 categorical）
    charts.append(upsert_chart(
        db, "② 月度 GMV 分布", "echarts_timeseries_bar",
        ds[(my, "monthly")],
        {
            "granularity_sqla": None,
            "time_range": "No filter",
            "x_axis": "month",
            "xAxisForceCategorical": True,
            "metrics": [adhoc_metric("gmv", "SUM", "GMV")],
            "groupby": [],
            "adhoc_filters": [],
            "row_limit": 10000,
            "x_axis_title": "月份",
            "y_axis_title": "GMV（元）",
            "show_legend": True,
            "rich_tooltip": True,
            "y_axis_format": ",.0f",
            "emitCrossFilters": True,
        },
        "month 是字符串月，不是时间戳，所以强制按分类轴渲染。"
        "开启 emitCrossFilters，点击某根柱子会把其它图表联动筛到该月。",
    ))

    # 3.3 月度趋势折线（与 3.2 同数据集同维度，用于验证联动）
    charts.append(upsert_chart(
        db, "③ 月度 GMV 趋势（联动用）", "echarts_timeseries_line",
        ds[(my, "monthly")],
        {
            "granularity_sqla": None,
            "time_range": "No filter",
            "x_axis": "month",
            "xAxisForceCategorical": True,
            "metrics": [adhoc_metric("gmv", "SUM", "GMV")],
            "groupby": [],
            "adhoc_filters": [],
            "row_limit": 10000,
            "x_axis_title": "月份",
            "seriesType": "smooth",
            "show_legend": True,
            "markerEnabled": True,
            "rich_tooltip": True,
            "y_axis_format": ",.0f",
            "emitCrossFilters": True,
        },
        "与 ② 同数据集，用来演示图表间联动（cross-filter）。",
    ))

    # 3.4 品类销售（柱状图）
    charts.append(upsert_chart(
        db, "④ 品类销售柱状图", "echarts_timeseries_bar",
        ds[(hive, "ads_category_topn")],
        {
            "granularity_sqla": None,
            "time_range": "No filter",
            "x_axis": "category",
            "xAxisForceCategorical": True,
            "metrics": [adhoc_metric("gmv", "SUM", "GMV")],
            "groupby": [],
            "adhoc_filters": [],
            "row_limit": 100,
            "x_axis_title": "品类",
            "xAxisLabelRotation": -30,
            "y_axis_title": "GMV（元）",
            "show_legend": False,
            "y_axis_format": ",.0f",
            "emitCrossFilters": True,
        },
        "ADS 层 Top8 品类的 GMV 对比，口径为订单实付金额。",
    ))

    # 3.5 门店 Top10（明细表）
    charts.append(upsert_chart(
        db, "⑤ 门店 GMV 排行 Top10", "table",
        ds[(hive, "ads_store_rank")],
        {
            "granularity_sqla": None,
            "time_range": "No filter",
            "query_mode": "raw",
            "all_columns": ["rank_no", "store_name", "gmv", "order_cnt"],
            "metrics": [],
            "groupby": [],
            "adhoc_filters": [],
            "order_by_cols": ['["rank_no", true]'],
            "row_limit": 10,
            "include_search": True,
            "show_cell_bars": True,
            "align_pn": False,
            "color_pn": False,
        },
        "ads_store_rank 已按 GMV 预排序，明细模式取前 10 行。",
    ))

    # 3.6 省份分布（中国地图）
    charts.append(upsert_chart(
        db, "⑥ 省份 GMV 分布", "country_map",
        ds[(my, "region")],
        {
            "granularity_sqla": None,
            "time_range": "No filter",
            "entity": "iso",
            "metric": adhoc_metric("gmv", "SUM", "GMV"),
            "adhoc_filters": [],
            "row_limit": 100,
            "select_country": "china",
            "linear_color_scheme": "blue_white_yellow",
            "number_format": "SMART_NUMBER",
            "is_redraw": True,
        },
        "entity 用 iso（CN-SN / CN-CQ…）。Superset 地图组件的关联键写死在 "
        "feature.properties.ISO 上（前端代码里是 country_id === properties.ISO），"
        "传中文省名或英文省名都匹配不到，只有 ISO 3166-2 能落图。",
    ))

    # 3.7 支付方式占比（饼图）
    charts.append(upsert_chart(
        db, "⑦ 支付方式占比", "pie",
        ds[(my, "pay_type")],
        {
            "granularity_sqla": None,
            "time_range": "No filter",
            "groupby": ["name"],
            "metric": adhoc_metric("gmv", "SUM", "GMV"),
            "adhoc_filters": [],
            "row_limit": 100,
            "label_type": "key_percent",
            "donut": True,
            "show_labels": True,
            "labels_outside": True,
            "show_legend": False,
            "color_scheme": "supersetColors",
            "number_format": ",.0f",
        },
        "微信 / 支付宝 / 银行卡 / 云闪付 的实付金额占比。",
    ))

    # 3.8 用户分层（环图）
    charts.append(upsert_chart(
        db, "⑧ 用户价值分层", "pie",
        ds[(hive, "ads_user_segment")],
        {
            "granularity_sqla": None,
            "time_range": "No filter",
            "groupby": ["user_segment"],
            "metric": adhoc_metric("user_cnt", "SUM", "用户数"),
            "adhoc_filters": [],
            "row_limit": 100,
            "label_type": "key_value",
            "donut": True,
            "show_labels": True,
            "labels_outside": True,
            "show_legend": False,
            "color_scheme": "supersetColors",
        },
        "按累计 GMV 分层的 5 个用户价值段。",
    ))

    log.info("== 4. 仪表板 ==")
    # 布局：①②③ 走势一排放上面；结构类 ④⑤⑥ 一排；⑦⑧ 两张环图各占半幅，
    # 环图放半幅宽是为了给外置标签留出空间（窄卡片里标签会被裁掉）。
    rows = [(charts[0:3], 4), (charts[3:6], 4), (charts[6:8], 6)]
    layout = build_layout(rows)
    native_filters = build_native_filters(ds[(my, "monthly")], charts)

    meta = {
        "color_scheme": "supersetColors",
        "refresh_frequency": 0,
        "expanded_slices": {},
        "timed_refresh_immune_slices": [],
        "default_filters": "{}",
        "cross_filters_enabled": True,   # 开启图表点选联动
        "native_filter_configuration": native_filters,
        # 每张图的联动作用域。只设 emitCrossFilters 是不够的：
        # 4.x 把"点某张图会筛哪些图"存在这里，缺省等于作用域为空，
        # 表现就是点击有 tooltip、别的图却纹丝不动。
        "chart_configuration": build_chart_configuration(charts),
        "global_chart_configuration": {"scope": {"rootPath": ["ROOT_ID"], "excluded": []}, "globalOpacity": {}},
    }

    dash = (
        db.session.query(Dashboard)
        .filter(Dashboard.slug == DASHBOARD_SLUG)
        .one_or_none()
    )
    if dash is None:
        dash = Dashboard()
        db.session.add(dash)
    dash.dashboard_title = DASHBOARD_TITLE
    dash.slug = DASHBOARD_SLUG
    dash.published = True
    dash.position_json = json.dumps(layout, ensure_ascii=False)
    dash.json_metadata = json.dumps(meta, ensure_ascii=False)
    dash.slices = charts
    db.session.commit()
    log.info("  [+] 仪表板 #%s %s", dash.id, DASHBOARD_SLUG)
    log.info("  URL: http://localhost:8088/superset/dashboard/%s/", DASHBOARD_SLUG)

    # 清理：改过名字的旧图表会留在库里（图表名是幂等键），
    # 它们既不在仪表板上，又会占着同名的权限记录，一并删掉。
    keep = {c.id for c in charts}
    prefix = tuple("①②③④⑤⑥⑦⑧⑨")
    stale = [
        s for s in db.session.query(Slice).all()
        if s.id not in keep and s.slice_name.startswith(prefix)
    ]
    for s in stale:
        log.info("  [-] 删除废弃图表 %s", s.slice_name)
        db.session.delete(s)
    db.session.commit()

    log.info("\n== 汇总 ==")
    log.info("  数据源 %d / 数据集 %d / 图表 %d / 仪表板 1",
             len(dbs), len(ds), db.session.query(Slice).count())


def build_chart_configuration(charts):
    """给每张图登记联动作用域：点自己，筛其它所有图。"""
    ids = [c.id for c in charts]
    cfg = {}
    for c in charts:
        cfg[str(c.id)] = {
            "id": c.id,
            "name": c.slice_name,
            "crossFilters": {
                "scope": "global",
                "chartsInScope": [i for i in ids if i != c.id],
            },
        }
    return cfg


def build_layout(rows, height=46):
    """按 (图表列表, 每张宽度) 的二维结构生成 position_json。

    Superset 的网格是 12 栅格：一行里所有卡片宽度之和应为 12，
    否则会出现右侧留白或横向滚动。
    """
    position = {
        "DASHBOARD_VERSION_KEY": "v2",
        "ROOT_ID": {"type": "ROOT", "id": "ROOT_ID", "children": ["GRID_ID"], "parents": []},
        "GRID_ID": {
            "type": "GRID",
            "id": "GRID_ID",
            "children": [f"ROW-{i}" for i in range(1, len(rows) + 1)],
            "parents": ["ROOT_ID"],
        },
        "HEADER_ID": {
            "type": "HEADER",
            "id": "HEADER_ID",
            "meta": {"text": DASHBOARD_TITLE},
        },
    }

    seq = 0
    for row_idx, (row_charts, width) in enumerate(rows, start=1):
        row_key = f"ROW-{row_idx}"
        child_keys = []
        for chart in row_charts:
            seq += 1
            key = f"CHART-{seq}"
            child_keys.append(key)
            position[key] = {
                "type": "CHART",
                "id": key,
                "children": [],
                "parents": ["ROOT_ID", "GRID_ID", row_key],
                "meta": {
                    "chartId": chart.id,
                    "width": width,
                    "height": height,
                    "sliceName": chart.slice_name,
                    "uuid": str(chart.uuid),
                },
            }
        position[row_key] = {
            "type": "ROW",
            "id": row_key,
            "children": child_keys,
            "parents": ["ROOT_ID", "GRID_ID"],
            "meta": {"background": "BACKGROUND_TRANSPARENT"},
        }

    return position

    return position


def build_native_filters(month_dataset, charts):
    """月份下拉筛选器：作用域挂到 ②③ 两张同源图上。"""
    scoped = [c.id for c in charts[1:3]]
    return [
        {
            "id": "NATIVE_FILTER-month01",
            "name": "月份",
            "filterType": "filter_select",
            "targets": [
                {
                    "datasetId": month_dataset.id,
                    "column": {"name": "month"},
                }
            ],
            "controlValues": {
                "enableEmptyFilter": False,
                "multiSelection": True,
                "inverseSelection": False,
                "searchAllOptions": True,
            },
            "defaultDataMask": {"extraFormData": {}, "filterState": {"value": None}, "ownState": {}},
            "cascadeParentIds": [],
            "scope": {"rootPath": ["ROOT_ID"], "excluded": []},
            "type": "NATIVE_FILTER",
            "description": "按自然月筛选 ②③ 两张月度图",
            "chartsInScope": scoped,
            "tabsInScope": ["TAB-NATIVE-FILTERS"],
            "sortMetric": None,
            "requiredFirst": False,
        }
    ]


if __name__ == "__main__":
    with app.app_context():
        try:
            build()
        except Exception as exc:  # noqa: BLE001
            from superset import db

            db.session.rollback()
            log.error("!! 失败：%s", exc)
            raise
    sys.exit(0)
