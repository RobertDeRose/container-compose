SWIFT ?= swift
BUILD_CONFIGURATION ?= release
PREFIX ?=
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
	./scripts/install.sh $(if $(PREFIX),--prefix "$(PREFIX)",)

package: stage
	./scripts/package.sh

lint:
	$(SWIFT) format lint --recursive Sources Tests
	for script in scripts/*.sh; do bash -n "$$script"; done
	sh -n Sources/ContainerCompose/Resources/container-compose-idle-shutdown
