# =============================================================
# Superset 镜像：在官方镜像基础上补齐三种驱动
#
# 为什么必须自己构建：apache/superset:4.1.1 只带 Flask 自身依赖，
# 连 MySQL 驱动都没有（pip list 里查不到 pymysql/mysqlclient），
# 更不用说 Hive 的 thrift 协议栈。直接拿官方镜像配数据源，
# 会卡在 "Could not load database driver" 上。
#
# 三个驱动各自的用途：
#   pymysql          —— Superset 元数据库 + MySQL 数据源
#   pyhive           —— 通过 HiveServer2 的 thrift 协议连 Hive
#   thrift-sasl      —— HiveServer2 的 SASL 认证层（pyhive 的硬依赖）
#   pure-sasl        —— 纯 Python 实现的 SASL，避免编译 libsasl2（镜像里没有 gcc）
#   clickhouse-connect —— ClickHouse 服务层数据源（纯 HTTP，无需编译）
# =============================================================
FROM apache/superset:4.1.1

USER root

ARG PIP_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple

RUN pip install --no-cache-dir -i ${PIP_INDEX} \
        pymysql==1.1.1 \
        pyhive==0.7.0 \
        thrift==0.16.0 \
        thrift-sasl==0.4.3 \
        pure-sasl==0.6.2 \
        clickhouse-connect==0.8.11 \
    && python -c "import pymysql, pyhive, thrift_sasl, clickhouse_connect; print('drivers ok')"

COPY superset_config.py /app/pythonpath/superset_config.py
COPY bootstrap.sh /app/bootstrap.sh
RUN chmod +x /app/bootstrap.sh

USER superset

ENV SUPERSET_CONFIG_PATH=/app/pythonpath/superset_config.py

# 必须覆盖官方镜像的默认 CMD（它直接 run-server.sh）。
# 直接在默认 CMD 上跑，会跳过建库 / 升级 schema / 建管理员这三步，
# 表现就是 worker 反复报 "Unknown database 'superset'" 然后退出。
CMD ["/bin/bash", "/app/bootstrap.sh"]
