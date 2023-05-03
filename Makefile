lc = $(subst A,a,$(subst B,b,$(subst C,c,$(subst D,d,$(subst E,e,$(subst F,f,$(subst G,g,$(subst H,h,$(subst I,i,$(subst J,j,$(subst K,k,$(subst L,l,$(subst M,m,$(subst N,n,$(subst O,o,$(subst P,p,$(subst Q,q,$(subst R,r,$(subst S,s,$(subst T,t,$(subst U,u,$(subst V,v,$(subst W,w,$(subst X,x,$(subst Y,y,$(subst Z,z,$1))))))))))))))))))))))))))
altarch = $(subst x86_64,amd64,$(subst aarch64,arm64,$1))

DEFAULT_GOAL := $(or $(DEFAULT_GOAL),toolchain)
ARCH := $(or $(ARCH),x86_64)
TARGET := $(or $(TARGET),$(ARCH))

normarch = $(subst arm64,aarch64,$(subst amd64,x86_64,$1))
HOST_ARCH := $(call normarch,$(call lc,$(shell uname -m)))
HOST_ARCH_ALT := $(call altarch,$(HOST_ARCH))

HOST_OS := $(call lc,$(shell uname -s))
PLATFORM := $(or $(PLATFORM),linux)
NAME := $(shell basename $(shell git rev-parse --show-toplevel | tr A-Z a-z ))
IMAGE := local/$(NAME)
UID := $(shell id -u)
GID := $(shell id -g)
USER := $(UID):$(GID)
CPUS := $(shell docker run -it debian nproc)
PRESERVE_CACHE := "false"
GIT_REF := $(shell git log -1 --format=%H)
GIT_AUTHOR := $(shell git log -1 --format=%an)
GIT_KEY := $(shell git log -1 --format=%GP)
GIT_TIMESTAMP := $(shell git log -1 --format=%cd --date=iso)
, := ,
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
	$(BIN_DIR) \
	$(OUT_DIR) \
	$(CACHE_DIR_ROOT)/toolchain.state \
	$(CACHE_DIR_ROOT)/toolchain.env

# Launch a shell inside the toolchain container
.PHONY: toolchain-shell
toolchain-shell: toolchain
	$(call toolchain,bash --norc,--interactive)

# Pin all packages in toolchain container to latest versions
.PHONY: toolchain-update
toolchain-update:
	docker run \
		--rm \
		--tty \
		--platform=linux/$(ARCH) \
		--env LOCAL_USER=$(UID):$(GID) \
		--volume $(PWD)/$(CONFIG_DIR):/config \
		--volume $(PWD)/$(SRC_DIR)/toolchain/scripts:/usr/local/bin \
		--cpus $(CPUS) \
		--volume $(PWD):/home/build \
		--workdir /home/build \
		debian@sha256:$(DEBIAN_HASH) \
		/usr/local/bin/packages-update

.PHONY: toolchain-clean
toolchain-clean:
	if [ -d "$(CACHE_DIR_ROOT)" ]; then \
		chmod -R u+w $(CACHE_DIR_ROOT); \
		rm -rf $(CACHE_DIR_ROOT); \
	fi
	if [ -d "$(OUT_DIR)" ]; then \
		rm -rf $(OUT_DIR); \
	fi
	docker image rm -f $(IMAGE) || :

.PHONY: reproduce
reproduce: toolchain-clean
	mkdir -p $(OUT_DIR)
	cp $(DIST_DIR)/release.env $(OUT_DIR)/release.env
	$(MAKE) TARGET=$(TARGET) VERSION=$(VERSION)
	diff -q $(OUT_DIR)/manifest.txt $(DIST_DIR)/manifest.txt \
	&& echo "Success: $(OUT_DIR) and $(DIST_DIR) are identical"

.PHONY: $(DIST_DIR)
$(DIST_DIR):
	rm -rf $@/*
	[ "$(PRESERVE_CACHE)" = "true" ] || $(MAKE) toolchain-clean
	$(MAKE) default
	cp -R $(OUT_DIR)/* $@/

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

$(OUT_DIR)/release.env: | $(OUT_DIR)
	echo 'VERSION=$(VERSION)'              > $(OUT_DIR)/release.env
	echo 'GIT_REF=$(GIT_REF)'             >> $(OUT_DIR)/release.env
	echo 'GIT_AUTHOR=$(GIT_AUTHOR)'       >> $(OUT_DIR)/release.env
	echo 'GIT_KEY=$(GIT_KEY)'             >> $(OUT_DIR)/release.env
	echo 'GIT_TIMESTAMP=$(GIT_TIMESTAMP)' >> $(OUT_DIR)/release.env

$(OUT_DIR)/manifest.txt: $(wildcard $(OUT_DIR)/*)
	find -L $(OUT_DIR) \
		-type f \
		-not -path "$(OUT_DIR)/manifest.txt" \
		-exec openssl sha256 -r {} \; \
	| sed -e 's/ \*out\// /g' -e 's/ \.\// /g' \
	| LC_ALL=C sort -k2 \
	> $@

check_executables := $(foreach exec,$(executables),\$(if \
	$(shell which $(exec)),some string,$(error "No $(exec) in PATH")))

define git_clone
	[ -d $(1) ] || \
		mkdir -p $(FETCH_DIR) && \
		mkdir $(1).tmp && \
		git -C $(1).tmp init && \
		git -C $(1).tmp remote add origin $(2) && \
		git -C $(1).tmp fetch origin $(3) && \
		git -C $(1).tmp -c advice.detachedHead=false checkout $(3) && \
		git -C $(1).tmp rev-parse --verify HEAD | grep -q $(3) || { \
			echo 'Error: Git ref/branch collision.'; exit 1; \
		} && \
		mv $(1).tmp $(1);
endef

define apply_patches
	[ -d $(2) ] && $(call toolchain," \
		cd $(1); \
		git restore .; \
		find /$(2) -type f -iname '*.patch' -print0 \
		| xargs -t -0 -n 1 patch -p1 --no-backup-if-mismatch -i ; \
	")
endef

define fetch_pgp_key
        mkdir -p $(KEY_DIR) && \
        $(call toolchain,' \
			for server in \
        	    keys.openpgp.org \
        	    hkp://keyserver.ubuntu.com:80 \
        	    hkp://p80.pool.sks-keyservers.net:80 \
        	    ha.pool.sks-keyservers.net \
        	    pgp.mit.edu \
        	; do \
        	                echo "Trying: $${server}"; \
        	        gpg \
        	                --keyserver "$${server}" \
        	                --keyserver-options timeout=10 \
        	                --recv-keys "$(1)" \
        	        && break; \
        	done; \
            gpg --export -a $(1) > $(KEY_DIR)/$(1).asc; \
        ')
endef

define toolchain
	docker run \
		--rm \
		--tty \
		$(2) \
		--env UID=$(UID) \
		--env GID=$(GID) \
		--platform=linux/$(ARCH) \
		--privileged \
		--cpus $(CPUS) \
		--volume $(PWD):/home/build \
		--workdir /home/build \
		--env-file=$(CONFIG_DIR)/global.env \
		--env-file=$(CACHE_DIR_ROOT)/toolchain.env \
		$(shell cat cache/toolchain.state 2> /dev/null) \
		$(SRC_DIR)/toolchain/scripts/host-env bash -c $(1)
endef
