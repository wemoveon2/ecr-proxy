lc = $(subst A,a,$(subst B,b,$(subst C,c,$(subst D,d,$(subst E,e,$(subst F,f,$(subst G,g,$(subst H,h,$(subst I,i,$(subst J,j,$(subst K,k,$(subst L,l,$(subst M,m,$(subst N,n,$(subst O,o,$(subst P,p,$(subst Q,q,$(subst R,r,$(subst S,s,$(subst T,t,$(subst U,u,$(subst V,v,$(subst W,w,$(subst X,x,$(subst Y,y,$(subst Z,z,$1))))))))))))))))))))))))))
altarch = $(subst x86_64,amd64,$(subst aarch64,arm64,$1))

TOOLCHAIN_VOLUME := $(PWD):/home/build
TOOLCHAIN_WORKDIR := /home/build
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
CPUS := $(shell docker run debian nproc)
ARCHIVE_SOURCES := true
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
FETCH_DIR := fetch
ifeq ($(TARGET),$(ARCH))
	CACHE_DIR := $(CACHE_DIR_ROOT)/$(TARGET)
else
	CACHE_DIR := $(CACHE_DIR_ROOT)/$(TARGET)/$(ARCH)
endif
BIN_DIR := $(CACHE_DIR_ROOT)/bin
SRC_DIR := src
KEY_DIR := fetch/keys
OUT_DIR := out
docker = docker

PATH_PREFIX := /home/build/.local/bin:/home/build/$(CACHE_DIR)/bin:/home/build/$(OUT_DIR)/linux/x86_64
PREFIX := $(HOME)/.local
XDG_CONFIG_HOME := $(HOME)/.config

export

include $(CONFIG_DIR)/make.env
export $(shell sed 's/=.*//' $(CONFIG_DIR)/make.env)

## Use env vars from existing release if present
ifeq ($(TOOLCHAIN_REPRODUCE),true)
include $(DIST_DIR)/release.env
export
endif

executables = $(docker) git git-lfs patch

.PHONY: toolchain
toolchain: \
	$(CACHE_DIR) \
	$(FETCH_DIR) \
	$(BIN_DIR) \
	$(OUT_DIR) \
	$(CACHE_DIR_ROOT)/toolchain.state \
	$(CACHE_DIR_ROOT)/container.env

# Launch a shell inside the toolchain container
.PHONY: toolchain-shell
toolchain-shell: toolchain
	$(call toolchain,bash --norc,--interactive)

.PHONY: toolchain-update
toolchain-update:
	rm -rf \
		$(CONFIG_DIR)/apt-pins-x86_64.list \
		$(CONFIG_DIR)/apt-sources-x86_64.list \
		$(CONFIG_DIR)/apt-hashes-x86_64.list \
		$(FETCH_DIR)/apt
	$(MAKE) $(CONFIG_DIR)/apt-hashes-x86_64.list

.PHONY: toolchain-restore-mtime
toolchain-restore-mtime:
	$(call toolchain," \
		git restore-mtime \
		&& echo "Git mtime restored" \
	")

.PHONY: toolchain-dist-cache
toolchain-dist-cache:
	mkdir -p $(OUT_DIR)
	cp -Rp $(DIST_DIR)/* $(OUT_DIR)/

$(CONFIG_DIR)/apt-base.list:
	touch $(CONFIG_DIR)/apt-base.list

# Regenerate toolchain dependency packages to latest versions
$(CONFIG_DIR)/apt-pins-x86_64.list \
$(CONFIG_DIR)/apt-sources-x86_64.list \
$(CONFIG_DIR)/apt-hashes-x86_64.list: \
$(CONFIG_DIR)/apt-base.list
	mkdir -p $(FETCH_DIR)/apt \
	&& docker run \
		--rm \
		--tty \
		--platform=linux/$(ARCH) \
		--env LOCAL_USER=$(UID):$(GID) \
		--volume $(PWD)/$(CONFIG_DIR):/config \
		--volume $(PWD)/$(SRC_DIR)/toolchain/scripts:/usr/local/bin \
		--cpus $(CPUS) \
		--volume $(TOOLCHAIN_VOLUME) \
		--workdir $(TOOLCHAIN_WORKDIR) \
		debian@sha256:$(DEBIAN_HASH) \
		/usr/local/bin/packages-update

# Pin all packages in toolchain container to latest versions
$(FETCH_DIR)/apt/Packages.bz2: $(CONFIG_DIR)/apt-hashes-x86_64.list
	docker run \
		--rm \
		--tty \
		--platform=linux/$(ARCH) \
		--env LOCAL_USER=$(UID):$(GID) \
		--env FETCH_DIR="$(FETCH_DIR)" \
		--env ARCHIVE_SOURCES=$(ARCHIVE_SOURCES) \
		--volume $(PWD)/$(CONFIG_DIR):/config \
		--volume $(PWD)/$(SRC_DIR)/toolchain/scripts:/usr/local/bin \
		--volume $(PWD)/$(FETCH_DIR):/fetch \
		--cpus $(CPUS) \
		--volume $(TOOLCHAIN_VOLUME) \
		--workdir $(TOOLCHAIN_WORKDIR) \
		debian@sha256:$(DEBIAN_HASH) \
		/usr/local/bin/packages-fetch

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

.PHONY: toolchain-reproduce
toolchain-reproduce: toolchain-clean
	mkdir -p $(OUT_DIR)
	$(MAKE) TOOLCHAIN_REPRODUCE="true"
	diff -q $(OUT_DIR) $(DIST_DIR) \
	&& echo "Success: $(OUT_DIR) and $(DIST_DIR) are identical"

.PHONY: toolchain-dist
toolchain-dist: toolchain-restore-mtime toolchain-dist-cache
	git ls-files -o --exclude-standard | grep . \
		&& { echo "Error: Git has untracked files present"; exit 1; } || :
	git diff --name-only | grep . \
		&& { echo "Error: Git has unstaged changes present"; exit 1; } || :
	[ "$(PRESERVE_CACHE)" = "true" ] || $(MAKE) toolchain-clean
	$(MAKE) default
	cp -Rp $(OUT_DIR)/* $(DIST_DIR)/

$(BIN_DIR):
	mkdir -p $@

$(CACHE_DIR):
	mkdir -p $@

$(FETCH_DIR):
	mkdir -p $@

$(OUT_DIR):
	mkdir -p $@

$(CACHE_DIR_ROOT)/container.env: \
	$(CONFIG_DIR)/make.env \
	$(CACHE_DIR_ROOT)/toolchain.state
	docker run \
        --rm \
        --env UID=$(UID) \
        --env GID=$(GID) \
		--env NAME="$(NAME)" \
		--env IMAGE="$(IMAGE)" \
		--env USER="$(USER)" \
		--env ARCH="$(ARCH)" \
		--env HOST_ARCH="$(HOST_ARCH)" \
		--env HOST_ARCH_ALT="$(HOST_ARCH_ALT)" \
		--env HOST_OS="$(HOST_OS)" \
		--env PLATFORM="$(PLATFORM)" \
		--env CPUS="$(CPUS)" \
		--env TARGET="$(TARGET)" \
		--env GIT_REF="$(GIT_REF)" \
		--env GIT_AUTHOR="$(GIT_AUTHOR)" \
		--env GIT_KEY="$(GIT_KEY)" \
		--env GIT_TIMESTAMP="$(GIT_TIMESTAMP)" \
		--env VERSION="$(VERSION)" \
		--env DIST_DIR="$(DIST_DIR)" \
		--env FETCH_DIR="$(FETCH_DIR)" \
		--env KEY_DIR="$(KEY_DIR)" \
		--env BIN_DIR="$(BIN_DIR)" \
		--env OUT_DIR="$(OUT_DIR)" \
		--env SRC_DIR="$(SRC_DIR)" \
		--env CACHE_DIR="$(CACHE_DIR)" \
		--env CACHE_DIR_ROOT="$(CACHE_DIR_ROOT)" \
		--env CONFIG_DIR="$(CONFIG_DIR)" \
		--env TOOLCHAIN_VOLUME="$(TOOLCHAIN_VOLUME)" \
		--env TOOLCHAIN_WORKDIR="$(TOOLCHAIN_WORKDIR)" \
        --platform=linux/$(ARCH) \
        --volume $(TOOLCHAIN_VOLUME) \
        --workdir $(TOOLCHAIN_WORKDIR) \
        $(shell cat cache/toolchain.state 2> /dev/null) \
        $(SRC_DIR)/toolchain/scripts/environment > $@

$(CACHE_DIR_ROOT)/toolchain.tar: \
	$(CONFIG_DIR)/make.env \
	$(SRC_DIR)/toolchain/Dockerfile \
	$(CONFIG_DIR)/apt-base.list \
	$(CONFIG_DIR)/apt-sources-$(ARCH).list \
	$(CONFIG_DIR)/apt-pins-$(ARCH).list \
	$(CONFIG_DIR)/apt-hashes-$(ARCH).list \
	| $(FETCH_DIR)/apt/Packages.bz2
	mkdir -p $(CACHE_DIR)
	DOCKER_BUILDKIT=1 \
	docker build \
		--tag $(IMAGE) \
		--build-arg DEBIAN_HASH=$(DEBIAN_HASH) \
		--build-arg CONFIG_DIR=$(CONFIG_DIR) \
		--build-arg FETCH_DIR=$(PWD)/$(FETCH_DIR) \
		--build-arg SCRIPTS_DIR=$(SRC_DIR)/toolchain/scripts \
		--platform=linux/$(ARCH) \
		-f $(SRC_DIR)/toolchain/Dockerfile \
		.
	docker save "$(IMAGE)" -o "$@"

$(CACHE_DIR_ROOT)/toolchain.state: \
	$(CACHE_DIR_ROOT)/toolchain.tar
	docker load -i $(CACHE_DIR_ROOT)/toolchain.tar
	docker images --no-trunc --quiet $(IMAGE) > $@

$(OUT_DIR)/release.env: $(shell git ls-files)
	echo 'VERSION=$(VERSION)'              > $(OUT_DIR)/release.env
	echo 'GIT_REF=$(GIT_REF)'             >> $(OUT_DIR)/release.env
	echo 'GIT_AUTHOR=$(GIT_AUTHOR)'       >> $(OUT_DIR)/release.env
	echo 'GIT_KEY=$(GIT_KEY)'             >> $(OUT_DIR)/release.env
	echo 'GIT_TIMESTAMP=$(GIT_TIMESTAMP)' >> $(OUT_DIR)/release.env

check_executables := $(foreach exec,$(executables),\$(if \
	$(shell which $(exec)),some string,$(error "No $(exec) in PATH")))

define sha256_file
$$(openssl sha256 $(1) | awk '{ print $$2}')
endef

define fetch_file
	bash -c " \
		echo \"Fetching $(1)\" \
		&& curl \
			--location $(1) \
			--output $(CACHE_DIR)/$(notdir $@) \
		&& [[ "\""$(call sha256_file,$(CACHE_DIR)/$(notdir $@))"\"" == "\""$(2)"\"" ]] \
		|| { echo 'Error: Hash check failed'; exit 1; } \
		&& mv $(CACHE_DIR)/$(notdir $@) $@; \
	"
endef

define git_archive
		$(call git_clone,$(CACHE_DIR)/$(notdir $@),$(1),$(2)) \
		&& tar \
				-C $(CACHE_DIR)/$(notdir $@) \
				--sort=name \
				--mtime='@0' \
				--owner=0 \
				--group=0 \
				--numeric-owner \
				-cvf - \
				. \
			| gzip -n > $@ \
		&& rm -rf $(CACHE_DIR)/$(notdir $@)
endef

define git_clone
	[ -d $(1) ] || \
		mkdir -p $(1).tmp && \
		git -C $(1).tmp init && \
		git -C $(1).tmp remote add origin $(2) && \
		git -C $(1).tmp fetch origin $(3) && \
		git -C $(1).tmp -c advice.detachedHead=false checkout $(3) && \
		git -C $(1).tmp submodule update --init && \
		git -C $(1).tmp rev-parse --verify HEAD | grep -q $(3) || { \
			echo 'Error: Git ref/branch collision.'; exit 1; \
		} && \
		mv $(1).tmp $(1)
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
            gpg --export -a $(1) > $@; \
        ')
endef

define toolchain
        $(MAKE) toolchain \
        && docker run \
                --rm \
                --tty \
                $(2) \
                --env UID=$(UID) \
                --env GID=$(GID) \
				--env PATH_PREFIX=$(PATH_PREFIX) \
                --platform=linux/$(ARCH) \
                --privileged \
                --cpus $(CPUS) \
                --volume $(TOOLCHAIN_VOLUME) \
                --workdir $(TOOLCHAIN_WORKDIR) \
                --env-file=$(CACHE_DIR_ROOT)/container.env \
                $$(cat $(CACHE_DIR_ROOT)/toolchain.state 2> /dev/null) \
                $(SRC_DIR)/toolchain/scripts/host-env bash -c $(1)
endef

