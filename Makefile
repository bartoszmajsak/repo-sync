PROJECT_DIR:=$(shell pwd)
SCRIPTS_DIR:=./scripts

ORG:=$(shell git remote get-url origin | cut -d':' -f 2 | cut -d'.' -f 1 | uniq | tail -n 1 | cut -d'/' -f 1)
REPO:=$(shell git remote get-url origin | cut -d':' -f 2 | cut -d'.' -f 1 | uniq | tail -n 1 | cut -d'/' -f 2)

# Call this function with $(call header,"Your message") to see underscored green text
define header =
@echo -e "\n\e[92m\e[4m\e[1m$(1)\e[0m\n"
endef

##@ Default target (all you need - just run "make")
.DEFAULT_GOAL:=all
.PHONY: all
all: test container-images

.PHONY: init
init:
	git submodule init
	git submodule update

##@ Source

.PHONY: test
test:
	$(call header,"Running tests")
	./test/bats/bin/bats test/*.bats

.PHONY: lint
lint:
	$(call header,"Running linters")
	shellcheck -a --severity=error $(SCRIPTS_DIR)/**
	hadolint Dockerfile.*

##@ Container Images

GITUNTRACKEDCHANGES:=$(shell git status --porcelain --untracked-files=no)
COMMIT:=$(shell git rev-parse --short HEAD)
ifneq ($(GITUNTRACKEDCHANGES),)
	COMMIT:=$(COMMIT)-dirty
endif

# Prefer to use podman if not explicitly set
ifneq (, $(shell which podman))
	IMG_BUILDER?=podman
else
	IMG_BUILDER?=docker
endif

.PHONY: container-images
container-images: container-image--create-patches ## Builds container images
container-images: container-image--validate-resolution
container-images: container-image--check-conflicts
container-images: container-image--propagate-patches

CONTAINER_REGISTRY?=quay.io
CONTAINER_REPOSITORY?=maistra-dev

container-image--%: ## Builds the container image
	$(eval image_param=$(subst container-image--,,$@))
	$(eval image_type=$(firstword $(subst @, ,$(image_param))))
	$(eval image_tag=$(or $(word 2,$(subst @, ,$(image_param))),latest))
	$(eval image_name:=prow-${image_type})
	$(call header,"Building container image $(image_name)")
	$(IMG_BUILDER) build \
		--label "org.opencontainers.image.title=$(image_name)" \
		--label "org.opencontainers.image.source=https://github.com/$(ORG)/$(REPO)" \
		--label "org.opencontainers.image.licenses=Apache-2.0" \
		--label "org.opencontainers.image.authors=Bartosz Majsak" \
		--label "org.opencontainers.image.vendor=Red Hat, Inc." \
		--label "org.opencontainers.image.revision=$(COMMIT)" \
		--label "org.opencontainers.image.created=$(shell date -u +%F\ %T%z)" \
		--network=host \
		-t $(CONTAINER_REGISTRY)/$(CONTAINER_REPOSITORY)/$(image_name):$(image_tag) \
		-f $(PROJECT_DIR)/Dockerfile.$(image_type) $(SCRIPTS_DIR)

.PHONY: container-images-push
container-images-push: container-images ## Pushes latest container images to the registry
container-images-push: container-push--create-patches@latest
container-images-push: container-push--propagate-patches@latest
container-images-push: container-push--validate-resolution@latest
container-images-push: container-push--check-conflicts@latest

container-push--%:
	$(eval image_param=$(subst container-push--,,$@))
	$(eval image_type=$(firstword $(subst @, ,$(image_param))))
	$(eval image_tag=$(or $(word 2,$(subst @, ,$(image_param))),latest))
	$(eval image_name:=prow-${image_type})
	$(call header,"Pushing container image $(image_name)")
	$(IMG_BUILDER) push $(CONTAINER_REGISTRY)/$(CONTAINER_REPOSITORY)/$(image_name):$(image_tag)

##@ Helpers

.PHONY: help
help:  ## Displays this help \o/
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-25s\033[0m\033[2m %s\033[0m\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)
	@cat $(MAKEFILE_LIST) | grep "^[A-Za-z_]*.?=" | sort | awk 'BEGIN {FS="?="; printf "\n\n\033[1mEnvironment variables\033[0m\n"} {printf "  \033[36m%-25s\033[0m\033[2m %s\033[0m\n", $$1, $$2}'
