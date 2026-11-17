# =============================================================
# Superset 运行配置
#
# 安全原则（对应任务书子任务 5）：
#   - 密钥一律从环境变量读，配置文件和镜像里不出现明文；
#   - SUPERSET_SECRET_KEY 由 .env 提供，未提供时**直接启动失败**，
#     而不是退化成默认值——默认值等于把会话签名公开。
# =============================================================
import os

# ---------------------------------------------------------------
# 一、密钥
# ---------------------------------------------------------------
SECRET_KEY = os.environ.get("SUPERSET_SECRET_KEY")
if not SECRET_KEY:
    raise RuntimeError(
        "缺少 SUPERSET_SECRET_KEY。请在 .env 中生成一个（openssl rand -base64 42），"
        "不要使用任何写死的示例值。"
    )

# ---------------------------------------------------------------
# 二、元数据库：MySQL
# 存放在业务 MySQL 的独立库 superset 里，和 Hive Metastore 的 metastore 库分开，
# 避免两套 schema 混在一个库里互相干扰。
# ---------------------------------------------------------------
_db_user = os.environ.get("MYSQL_USER", "root")
_db_pass = os.environ.get("MYSQL_ROOT_PASSWORD", "root")
_db_host = os.environ.get("MYSQL_HOST", "mysql")
_db_port = os.environ.get("MYSQL_PORT", "3306")
SQLALCHEMY_DATABASE_URI = (
    f"mysql+pymysql://{_db_user}:{_db_pass}@{_db_host}:{_db_port}/superset"
    "?charset=utf8mb4"
)

# ---------------------------------------------------------------
# 三、驱动别名：把 pymysql 冒充成 MySQLdb
#
# 现象：数据源已经能连上（SQL Lab 能出数），但任何图表都报
#   Error: No module named 'MySQLdb'
# 原因是 Superset 的 MySQLEngineSpec 有两处写死了 `import MySQLdb`：
# 一处是驱动自检，一处是默认参数探测；即使 URI 里明确写了
# mysql+pymysql:// 也绕不过去。
#
# 装 mysqlclient 要现场编译（镜像里没有 gcc/libmysqlclient-dev），
# 用 PyMySQL 官方提供的兼容层更轻：它把自身注册成 sys.modules['MySQLdb']。
# ---------------------------------------------------------------
import pymysql

pymysql.install_as_MySQLdb()

# ---------------------------------------------------------------
# 四、功能开关
# ---------------------------------------------------------------
# 允许在 SQL Lab 里写 SQL（本项目需要现场演示 Hive 查询）
FEATURE_FLAGS = {
    "ENABLE_TEMPLATE_PROCESSING": True,
    "DASHBOARD_RBAC": False,
    "EMBEDDED_SUPERSET": False,
    # 图表点选联动。config.py 里虽然默认给了 True，但这里一旦整体重写
    # FEATURE_FLAGS，默认值就丢了——表现是仪表板上点柱子没有任何反应。
    "DASHBOARD_CROSS_FILTERS": True,
}

# 关掉示例数据加载，减少启动时间和无关表
SUPERSET_LOAD_EXAMPLES = False

# 查询超时（秒）：Hive 走 Tez，冷启动会慢一些
SQLLAB_TIMEOUT = 120
SUPERSET_WEBSERVER_TIMEOUT = 120

# 关闭匿名使用，所有访问都要登录
PUBLIC_ROLE_LIKE = "Gamma"
AUTH_ROLE_PUBLIC = "Public"

# 会话与上传
SESSION_COOKIE_SECURE = False          # 本地 http 演示；上生产必须置 True
SESSION_COOKIE_HTTPONLY = True
SESSION_COOKIE_SAMESITE = "Lax"

# 行数上限：避免误查大表把浏览器拖死
ROW_LIMIT = 5000
SAMPLES_ROW_LIMIT = 1000

# 中文界面
BABEL_DEFAULT_LOCALE = "zh"
LANGUAGES = {"zh": {"flag": "cn", "name": "Chinese"}, "en": {"flag": "us", "name": "English"}}

# 日志
import logging
logging.basicConfig(level=logging.INFO)

# ---------------------------------------------------------------
# 兼容性补丁：Hive 4.0.0（Tez 版）不支持 SHOW CATALOGS
#
# 现象：新建 Hive 数据源时返回 422 "Database could not be created"，
# 日志里真正的错误是
#   ParseException line 1:5 cannot recognize input near 'SHOW' 'CATALOGS'
# 原因是 Superset 4.1 的 Hive engine spec 声明了 supports_catalog=True，
# 建库时会先探测 catalog 列表给权限用，而 apache/hive:4.0.0 这个构建
# 没有 catalog 语法。
#
# 处理方式：把该 engine spec 的 catalog 能力关掉，走 Superset 的
# 「无 catalog 数据库」分支（catalogs=[None]）。比换 Superset 版本或
# 改 Hive 镜像都更小、更可控，也不会影响其他数据源。
# ---------------------------------------------------------------
try:
    from superset.db_engine_specs.hive import HiveEngineSpec
    HiveEngineSpec.supports_catalog = False
except Exception:  # 升级 Superset 后类名/属性可能变化，失败不影响启动
    pass
