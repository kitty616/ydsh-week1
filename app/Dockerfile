# =============================================================
# 应用镜像：Streamlit 问答 + 大屏 JSON 接口
#
# 构建上下文是仓库根目录（不是 app/），因为镜像里要带：
#   python/    第 3 周的 NL2SQL 内核（复用，不重写）
#   data/      schema_prompt.txt / hive_schema.json
#   dashboard/ ECharts 本地库（图表库不打 CDN，断网也能渲染）
#
# 一处细节：app.py 用 BASE = dirname(dirname(__file__)) 定位仓库根，
# 所以这里必须保持 app/app.py 的目录层级，不能把 app.py 直接放到 /app。
# =============================================================
FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple

WORKDIR /app

COPY app/requirements.txt /app/requirements.txt
RUN pip install -r /app/requirements.txt

COPY app/ /app/app/
COPY python/ /app/python/
COPY data/ /app/data/
COPY dashboard/ /app/dashboard/

EXPOSE 8501 8000

HEALTHCHECK --interval=20s --timeout=5s --start-period=40s --retries=6 \
    CMD python -c "import urllib.request,os; \
port=os.environ.get('HEALTH_PORT','8501'); \
urllib.request.urlopen(f'http://127.0.0.1:{port}/_stcore/health' if port=='8501' else f'http://127.0.0.1:8000/api/health', timeout=4)" \
    || exit 1

CMD ["streamlit", "run", "app/app.py", \
     "--server.port=8501", "--server.address=0.0.0.0", \
     "--server.headless=true", "--browser.gatherUsageStats=false"]
