ifeq ("$(wildcard $(PWD)/src/toolchain)","")
define ERROR
Toolchain submodule not present. You likely need to run:

git submodule update --init --recursive

and then run make again
endef
        $(error $(ERROR))
endif

include $(PWD)/src/toolchain/Makefile

KEYS := \
	6B61ECD76088748C70590D55E90A401336C8AAA9 \
	A8864A8303994E3A18ACD1760CAB4418C834B102 \
	66039AA59D823C8BD68DB062D3EC673DF9843E7B \
	DE050A451E6FAF94C677B58B9361DEC647A087BD

LOCAL_BUILD_DIR := 'build'

.DEFAULT_GOAL :=
.PHONY: default
default: \
	toolchain \
	$(patsubst %,$(KEY_DIR)/%.asc,$(KEYS)) \
	$(OUT_DIR)/ecr-proxy.linux-x86_64 \
	$(OUT_DIR)/ecr-proxy.linux-aarch64 \
	$(OUT_DIR)/release.env \
	toolchain-profile

.PHONY: lint
lint:
	$(call toolchain,' \
		GOCACHE=/home/build/$(CACHE_DIR) \
		GOPATH=/home/build/$(CACHE_DIR) \
		env -C $(SRC_DIR) go vet -v ./... \
	')

.PHONY: test
test: $(OUT_DIR)/ecr-proxy.linux-x86_64
	$(call toolchain,' \
		GOCACHE=/home/build/$(CACHE_DIR) \
		GOPATH=/home/build/$(CACHE_DIR) \
		env -C $(SRC_DIR) go test -v ./... \
	')

.PHONY: install
install: default
	mkdir -p ~/.local/bin
	cp $(OUT_DIR)/ecr-proxy.$(HOST_OS)-$(HOST_ARCH) ~/.local/bin/ecr-proxy

# Clean repo back to initial clone state
.PHONY: clean
clean: toolchain-clean
	git clean -dfx $(SRC_DIR)
	rm -rf $(LOCAL_BUILD_DIR)

$(KEY_DIR)/%.asc:
	$(call fetch_pgp_key,$(basename $(notdir $@)))

$(OUT_DIR)/ecr-proxy.%:
	$(call toolchain,' \
		GOHOSTOS="linux" \
		GOHOSTARCH="amd64" \
		GOOS="$(word 1,$(subst -, ,$(word 2,$(subst ., ,$@))))" \
		GOARCH="$(call altarch,$(word 2,$(subst -, ,$(word 2,$(subst ., ,$@)))))" \
		GOCACHE=/home/build/$(CACHE_DIR) \
		GOPATH=/home/build/$(CACHE_DIR) \
		CGO_ENABLED=0 \
		env -C $(SRC_DIR)/cmd/ecr-proxy \
		go build \
			-trimpath \
			-o /home/build/$@ . \
	')

.PHONY: build-local
build-local:
	pushd $(shell git rev-parse --show-toplevel)/src; \
	go build -o ../$(LOCAL_BUILD_DIR)/ecr-proxy; \
	popd;
