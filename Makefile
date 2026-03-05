SHELL := /bin/bash

.PHONY: help env test-if-match test-if-not-match test-all

env:
	@if [[ -f .env ]]; then \
		echo ".env already exists"; \
	else \
		cp .env.example .env; \
		echo "Created .env from .env.example"; \
	fi

test-if-match:
	@bash ./test_put_if_match.sh

test-if-not-match:
	@bash ./test_put_if_not_match.sh

test-all: test-if-match test-if-not-match
