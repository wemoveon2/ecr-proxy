DEFAULT_GOAL := $(or $(DEFAULT_GOAL),toolchain)
ARCH := $(or $(ARCH),x86_64)
TARGET := $(or $(TARGET),$(ARCH))
PLATFORM := $(or $(PLATFORM),linux)
NAME := $(shell basename $(shell git rev-parse --show-toplevel | tr A-Z a-z ))
IMAGE := local/$(NAME)
USER := $(shell id -u):$(shell id -g)
CPUS := $(shell docker run -it debian nproc)
GIT_REF := $(shell git log -1 --format=%H)
GIT_AUTHOR := $(shell git log -1 --format=%an)
GIT_KEY := $(shell git log -1 --format=%GP)
GIT_TIMESTAMP := $(shell git log -1 --format=%cd --date=iso)
ifeq ($(strip $(shell git status --porcelain 2>/dev/null)),)
	GIT_STATE=clean
else
	GIT_STATE=dirty
endif
VERSION := $(shell TZ=UTC0 git show --quiet --date='format-local:%Y.%m.%d' --format="%cd")
DIST_DIR := dist
CONFIG_DIR := config
CACHE_DIR_ROOT := cache
FETCH_DIR := $(CACHE_DIR_ROOT)/fetch
ifeq ($(TARGET),$(ARCH))
	CACHE_DIR := $(CACHE_DIR_ROOT)/$(TARGET)
else
	CACHE_DIR := $(CACHE_DIR_ROOT)/$(TARGET)/$(ARCH)
endif
BIN_DIR := $(CACHE_DIR_ROOT)/bin
SRC_DIR := src
KEY_DIR := keys
OUT_DIR := out

export

docker = docker

include $(CONFIG_DIR)/global.env
export $(shell sed 's/=.*//' $(CONFIG_DIR)/global.env)

## Use env vars from existing release if present
ifneq (,$(wildcard $(DIST_DIR)/release.env))
    include $(DIST_DIR)/release.env
    export
endif

executables = $(docker) git patch

.PHONY: toolchain
toolchain: \
	$(CACHE_DIR) \
	$(FETCH_DIR) \
	$(DIST_DIR) \
	$(BIN_DIR) \
	$(OUT_DIR) \
	$(CACHE_DIR_ROOT)/toolchain.tar \
	$(CACHE_DIR_ROOT)/toolchain.state \
	$(CACHE_DIR_ROOT)/toolchain.env

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

.PHONY: toolchain-clean
toolchain-clean:
	rm -rf $(CACHE_DIR_ROOT) $(OUT_DIR)
	docker image rm -f $(IMAGE)

.PHONY: attest
attest: toolchain-clean
	mkdir -p $(OUT_DIR)
	cp $(DIST_DIR)/release.env $(OUT_DIR)/release.env
	$(MAKE) TARGET=$(TARGET) VERSION=$(VERSION)
	diff -q $(OUT_DIR)/manifest.txt $(DIST_DIR)/manifest.txt;

$(DIST_DIR):
	mkdir -p $@

$(BIN_DIR):
	mkdir -p $@

$(CACHE_DIR):
	mkdir -p $@

$(FETCH_DIR):
	mkdir -p $@

$(OUT_DIR):
	mkdir -p $@

$(CACHE_DIR_ROOT)/toolchain.env: \
	$(CACHE_DIR) \
	$(SRC_DIR)/toolchain/scripts/environment
	$(SRC_DIR)/toolchain/scripts/environment > $@

$(CACHE_DIR_ROOT)/toolchain.tar: \
	$(SRC_DIR)/toolchain/Dockerfile \
	$(CONFIG_DIR)/toolchain/package-hashes-$(ARCH).txt \
	$(CONFIG_DIR)/toolchain/packages-base.list \
	$(CONFIG_DIR)/toolchain/packages-$(ARCH).list \
	$(CONFIG_DIR)/toolchain/sources.list
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

$(CACHE_DIR_ROOT)/toolchain.state: \
	$(CACHE_DIR_ROOT)/toolchain.tar
	docker load -i $(CACHE_DIR_ROOT)/toolchain.tar
	docker images --no-trunc --quiet $(IMAGE) > $@

$(DIST_DIR)/release.env: \
	$(DIST_DIR) \
	$(OUT_DIR)/release.env
	cp $(OUT_DIR)/release.env $(DIST_DIR)/release.env

$(DIST_DIR)/manifest.txt: \
	$(DIST_DIR) \
	$(OUT_DIR)/manifest.txt
	cp $(OUT_DIR)/manifest.txt $(DIST_DIR)/manifest.txt

$(OUT_DIR)/release.env: | $(OUT_DIR)
	echo 'VERSION=$(VERSION)'              > $(OUT_DIR)/release.env
	echo 'GIT_REF=$(GIT_REF)'             >> $(OUT_DIR)/release.env
	echo 'GIT_AUTHOR=$(GIT_AUTHOR)'       >> $(OUT_DIR)/release.env
	echo 'GIT_KEY=$(GIT_KEY)'             >> $(OUT_DIR)/release.env
	echo 'GIT_TIMESTAMP=$(GIT_TIMESTAMP)' >> $(OUT_DIR)/release.env

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
	[ -d $(1) ] || git clone $(2) $(1)
	git -C $(1) checkout $(3)
	git -C $(1) rev-parse --verify HEAD | grep -q $(3) || { \
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

define fetch_pgp_key
        mkdir -p $(KEY_DIR) && \
        $(call toolchain,$(USER), " \
                for server in \
            ha.pool.sks-keyservers.net \
            hkp://keyserver.ubuntu.com:80 \
            hkp://p80.pool.sks-keyservers.net:80 \
            pgp.mit.edu \
        ; do \
                        echo "Trying: $${server}"; \
                gpg \
                        --recv-key \
                        --keyserver "$${server}" \
                        --keyserver-options timeout=10 \
                        --recv-keys "$(1)" \
                && break; \
        done; \
                gpg --export -a $(1) > $(KEY_DIR)/$(1).asc; \
        ")
endef

define toolchain
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
		--env-file=$(CACHE_DIR_ROOT)/toolchain.env \
		$(shell cat cache/toolchain.state) \
		bash -c $(2)
endef
