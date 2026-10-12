SWIFT ?= swift
BUILD_CONFIGURATION ?= release
PREFIX ?=
REPLACE ?=
VERSION ?=
export BUILD_CONFIGURATION VERSION

.PHONY: build test stage install package lint
build:
	$(SWIFT) build -c $(BUILD_CONFIGURATION) --product compose

test:
	$(SWIFT) test
	./scripts/test-install.sh

stage: build
	./scripts/stage.sh

install: stage
	./scripts/install.sh $(if $(PREFIX),--prefix "$(PREFIX)",) $(if $(REPLACE),--replace,)

package: stage
	./scripts/package.sh

lint:
	$(SWIFT) format lint --recursive Sources Tests
	for script in scripts/*.sh; do bash -n "$$script"; done
	sh -n machine-image/container-compose-idle-shutdown
