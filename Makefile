.PHONY: help setup server app run test clean

VENV := server/.venv
PY   := $(VENV)/bin/python

help:
	@echo "MixDictate"
	@echo ""
	@echo "  make setup   安装 Python 依赖（含 mlx-qwen3-asr，仅 Apple Silicon）"
	@echo "  make server  启动本地转写服务（前台运行，保持这个终端开着）"
	@echo "  make app     编译并打包菜单栏 App"
	@echo "  make test    跑后处理单元测试（不需要模型，任何平台都能跑）"
	@echo "  make clean   清理构建产物"

setup:
	python3 -m venv $(VENV)
	$(PY) -m pip install --upgrade pip
	$(PY) -m pip install -e "./server[dev]"
	@if [ "$$(uname -m)" = "arm64" ]; then \
		echo "==> 检测到 Apple Silicon，安装 mlx-qwen3-asr"; \
		$(PY) -m pip install -e "./server[mlx]"; \
	else \
		echo "==> 非 Apple Silicon，跳过 mlx-qwen3-asr（可用 MIXDICTATE_BACKEND=mock 跑通链路）"; \
	fi

server:
	$(PY) -m mixdictate_server.main

# 不加载模型的空跑模式，用来验证 App 到服务的链路是否打通
server-mock:
	MIXDICTATE_BACKEND=mock MIXDICTATE_MOCK_TEXT="嗯,这个pipeline的latency有点高" $(PY) -m mixdictate_server.main

app:
	./scripts/build_app.sh

run: app
	open build/MixDictate.app

test:
	$(PY) -m pytest server/tests -q

clean:
	rm -rf build app/.build server/**/__pycache__ .pytest_cache
