NAME := $(shell basename $(shell git rev-parse --show-toplevel))
IMAGE := local/$(NAME):latest
ARCH := x86_64
TARGET := $(ARCH)
USER := $(shell id -u):$(shell id -g)
CPUS := $(shell docker run -it debian nproc)
GIT_REF := $(shell git log -1 --format=%H config)
GIT_AUTHOR := $(shell git log -1 --format=%an config)
GIT_KEY := $(shell git log -1 --format=%GP config)
GIT_EPOCH := $(shell git log -1 --format=%at config)
GIT_DATETIME := \
	$(shell git log -1 --format=%cd --date=format:'%Y-%m-%d %H:%M:%S' config)
ifeq ($(strip $(shell git status --porcelain 2>/dev/null)),)
	GIT_STATE=clean
else
	GIT_STATE=dirty
endif
VERSION := $(shell TZ=UTC0 git show --quiet --date='format-local:%Y%m%dT%H%M%SZ' --format="%cd")
RELEASE_DIR := release/$(VERSION)
CONFIG_DIR := config
CACHE_DIR := cache
SRC_DIR := src
OUT_DIR := out
docker = docker

include $(CONFIG_DIR)/global.env
export $(shell sed 's/=.*//' $(CONFIG_DIR)/global.env)

## Use env vars from existing release if present
ifneq (,$(wildcard $(RELEASE_DIR)/release.env))
    include $(RELEASE_DIR)/release.env
    export
endif

executables = $(docker) git patch

.PHONY: toolchain
toolchain: $(CACHE_DIR)/toolchain.tar $(CACHE_DIR)/toolchain.env

# Launch a shell inside the toolchain container
.PHONY: toolchain-shell
toolchain-shell: toolchain
	$(call toolchain,$(USER),"bash --norc")

# Pin all packages in toolchain container to latest versions
.PHONY: toolchain-update
toolchain-update:
	docker run \
		--rm \
		--env LOCAL_USER=$(USER) \
		--platform=linux/$(ARCH) \
		--volume $(PWD)/$(CONFIG_DIR):/config \
		--volume $(PWD)/$(SRC_DIR)/toolchain/scripts:/usr/local/bin \
		--env ARCH=$(ARCH) \
		--interactive \
		--tty \
		debian@sha256:$(DEBIAN_HASH) \
		bash -c /usr/local/bin/packages-update

.PHONY: attest
attest:
	rm -rf $(CACHE_DIR) $(OUT_DIR)
	$(MAKE)
	diff -q $(OUT_DIR)/manifest.txt release/$(VERSION)/manifest.txt;

$(RELEASE_DIR):
	mkdir -p $@

$(CACHE_DIR):
	mkdir -p $@

$(OUT_DIR):
	mkdir -p $@

.ONESHELL:
$(CACHE_DIR)/toolchain.env: $(CACHE_DIR)
	cat <<- EOF > $@
		HOME=/home/build
		PS1=$(NAME)-toolchain
		GNUPGHOME=/cache/.gnupg
		ARCH=$(ARCH)
		TARGET=$(ARCH)
		GIT_REF=$(GIT_REF)
		GIT_AUTHOR=$(GIT_AUTHOR)
		GIT_KEY=$(GIT_KEY)
		GIT_DATETIME=$(GIT_DATETIME)
		GIT_EPOCH=$(GIT_EPOCH)
		FAKETIME_FMT="%s"
		FAKETIME="1"
		SOURCE_DATE_EPOCH=1
		KBUILD_BUILD_TIMESTAMP="1970-01-01 00:00:00 UTC"
		KCONFIG_NOTIMESTAMP=1
		KBUILD_BUILD_USER=root
		KBUILD_BUILD_HOST=$(NAME)
		KBUILD_BUILD_VERSION=1
		UID=$(shell id -u)
		GID=$(shell id -g)
		RELEASE_DIR=release/$(VERSION)
		CONFIG_DIR=/home/build/$(CONFIG_DIR)
		CACHE_DIR=/home/build/$(CACHE_DIR)
		SRC_DIR=/home/build/$(SRC_DIR)
		OUT_DIR=/home/build/$(OUT_DIR)
	EOF

$(CACHE_DIR)/toolchain.tar:
	mkdir -p $(CACHE_DIR)
	DOCKER_BUILDKIT=1 \
	docker build \
		--tag $(IMAGE) \
		--build-arg DEBIAN_HASH=$(DEBIAN_HASH) \
		--build-arg CONFIG_DIR=$(CONFIG_DIR) \
		--build-arg SCRIPTS_DIR=$(SRC_DIR)/toolchain/scripts \
		--platform=linux/$(ARCH) \
		-f $(SRC_DIR)/toolchain/Dockerfile \
		.
	docker save "$(IMAGE)" -o "$@"

$(RELEASE_DIR)/release.env: \
	$(RELEASE_DIR) \
	$(OUT_DIR)/release.env
	cp $(OUT_DIR)/release.env $(RELEASE_DIR)/release.env

$(RELEASE_DIR)/manifest.txt: \
	$(RELEASE_DIR) \
	$(OUT_DIR)/manifest.txt
	cp $(OUT_DIR)/manifest.txt $(RELEASE_DIR)/manifest.txt

$(OUT_DIR)/release.env: | $(OUT_DIR)
	echo 'VERSION=$(VERSION)'            > $(OUT_DIR)/release.env
	echo 'GIT_REF=$(GIT_REF)'           >> $(OUT_DIR)/release.env
	echo 'GIT_AUTHOR=$(GIT_AUTHOR)'     >> $(OUT_DIR)/release.env
	echo 'GIT_KEY=$(GIT_KEY)'           >> $(OUT_DIR)/release.env
	echo 'GIT_DATETIME=$(GIT_DATETIME)' >> $(OUT_DIR)/release.env

$(OUT_DIR)/manifest.txt: | $(OUT_DIR)
	find $(OUT_DIR) \
		-type f \
		-not -path "$(OUT_DIR)/manifest.txt" \
		-exec openssl sha256 -r {} \; \
	| sed -e 's/ \*/ /g' -e 's/ \.\// /g' \
	| LC_ALL=C sort -k2 \
	> $@

check_executables := $(foreach exec,$(executables),\$(if \
	$(shell which $(exec)),some string,$(error "No $(exec) in PATH")))

define git_clone
	[ -d $(CACHE_DIR)/$(1) ] || git clone $(2) $(CACHE_DIR)/$(1)
	git -C $(CACHE_DIR)/$(1) checkout $(3)
	git -C $(CACHE_DIR)/$(1) rev-parse --verify HEAD | grep -q $(3) || { \
		echo 'Error: Git ref/branch collision.'; exit 1; \
	};
endef

define apply_patches
	[ -d $(2) ] && $(call toolchain,$(USER)," \
		cd $(1); \
		git restore .; \
		find /$(2) -type f -iname '*.patch' -print0 \
		| xargs -t -0 -n 1 patch -p1 --no-backup-if-mismatch -i ; \
	")
endef

define toolchain
	docker load -i $(CACHE_DIR)/toolchain.tar
	docker run \
		--rm \
		--tty \
		--interactive \
		--user=$(1) \
		--platform=linux/$(ARCH) \
		--cpus $(CPUS) \
		--volume $(PWD):/home/build \
		--workdir /home/build \
		--env-file=$(CONFIG_DIR)/global.env \
		--env-file=$(CACHE_DIR)/toolchain.env \
		$(IMAGE) \
		bash -c $(2)
endef
