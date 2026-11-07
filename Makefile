PYTHON ?= /usr/bin/python3.12

.PHONY: format-setup format format-check
format-setup:
	$(PYTHON) tools/install_formatters.py

format:
	$(PYTHON) tools/format_code.py

format-check:
	$(PYTHON) tools/format_code.py --check
