.PHONY: help install app test dev-setup dev-server dev-server-mock clean

VENV := server/.venv
PY   := $(VENV)/bin/python

help:
	@echo "MixDictate"
	@echo ""
	@echo "  普通使用："
	@echo "    ./install.sh   一键安装：建环境、编译、装进「应用程序」"
	@echo "                   装完双击 App 就行，不用再碰终端"
	@echo ""
	@echo "  make app         只重新编译 App（改了 Swift 代码之后）"
	@echo "  make test        跑测试（不需要模型，任何平台都能跑）"
	@echo ""
	@echo "  开发用："
	@echo "    make dev-setup       在 server/.venv 建独立的开发环境"
	@echo "    make dev-server      前台跑服务，看实时日志"
	@echo "    make dev-server-mock 不加载模型空跑，验证链路"
	@echo ""
	@echo "  注意：开发环境(server/.venv) 和 App 用的环境"
	@echo "  (~/Library/Application Support/MixDictate/venv) 是分开的。"

install:
	./install.sh

app:
	./scripts/build_app.sh

test: $(VENV)
	$(PY) -m pytest server/tests -q

# ---------------------------------------------------------------- 开发

$(VENV):
	@$(MAKE) dev-setup

dev-setup:
	python3 -m venv $(VENV)
	$(PY) -m pip install --upgrade pip
	$(PY) -m pip install -e "./server[dev]"
	@if [ "$$(uname -m)" = "arm64" ] && [ "$$(uname -s)" = "Darwin" ]; then \
		echo "==> Apple Silicon，装 mlx-qwen3-asr"; \
		$(PY) -m pip install -e "./server[mlx]"; \
	else \
		echo "==> 非 Apple Silicon，跳过 mlx（用 dev-server-mock 验证链路）"; \
	fi

dev-server:
	$(PY) -m mixdictate_server.main

dev-server-mock:
	MIXDICTATE_BACKEND=mock MIXDICTATE_MOCK_TEXT="嗯,这个pipeline的latency有点高" $(PY) -m mixdictate_server.main

clean:
	rm -rf build app/.build .pytest_cache
	find . -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true
