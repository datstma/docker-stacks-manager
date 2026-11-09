PREFIX ?= $(HOME)/.local

.PHONY: help install uninstall test lint screenshots

help:
	@echo "make install     install into \$$(PREFIX)/bin (PREFIX=$(PREFIX))"
	@echo "make uninstall   remove it again"
	@echo "make test        run the test suite (no Docker needed)"
	@echo "make lint        shellcheck, errors only"
	@echo "make screenshots re-record docs/images (needs Docker)"

install:
	./install.sh --prefix "$(PREFIX)"

uninstall:
	./install.sh --prefix "$(PREFIX)" --uninstall

test:
	./tests/run.sh

lint:
	shellcheck -S error docker-stacks-manager.sh install.sh tests/run.sh tests/record.sh tests/bin/docker demo/demo.sh demo/screenshots/screenshots.sh

screenshots:
	./demo/screenshots/screenshots.sh
