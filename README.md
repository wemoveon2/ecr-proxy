# Toolchain #

<https://codeberg.org/distrust/toolchain>

## About ##

A library of opinionated make functions targeting projects that either need
deterministic builds, or a deterministic toolchain shared across all who use a
project.

A dev of a Toolchain enabled project should never need to have anything
on their host system installed but docker, and git. Everything else will be
provided via a Docker container.

Debian currently has the highest reproducibility score of any major Linux
distribution, and as such it is the chosen base for Toolchain.

This was built for Distrust projects, and some of our clients. It is unlikely
to meet the needs of everyone. We suggest including this in your project as
a git subtree, so you can make your own changes, but also pull in changes from
us as desired.

## Uses ##
 * Ensure everyone on a team is using the exact same tools
 * Ensure all releases and artifacts build hash-for-hash identical every time
 * Control supply chain security with only signed/reproducible dependencies

## Features ##
 * Can run a shell with all toolchain tooling in the current directory
 * Provide make functions for common tasks
   * Git clone, apply patches, etc.
 * Use a global env file as configuration
 * Hash-locking of apt dependencies from a list of top-level required packages
 * Provides release.env file with required vars to re-create old releases

## Requirements ##

* docker 18+
* GNU Make 4+

## Setup ##

1. Clone toolchain as a git submodule somewhere in your project

    ```
    git submodule add https://codeburg.org/distrust/toolchain src/toolchain
    ```

2. Include toolchain Makefile in your root Makefile

    ```
    include src/toolchain/Makefile
    ```

3. Define any build/dev dependencies for toolchain container

    ```
    echo "libfaketime" >> config/toolchain/packages-base.txt
    echo "build-essential" >> config/toolchain/packages-base.txt
    ```

4. Lock a base Debian container image hash

    ```
    echo "DEBIAN_HASH=48b28b354484a7f0e683e340fa0e6e4c4bce3dc3aa0146fc2f78f443fde2c55d" >> config/global.env
    ```

5. Generate hashlocks files for all toolchain container dependencies
    ```
    make toolchain-update
    ```

6. Define your artifact targets

    ```
    $(OUT_DIR)/hello: toolchain \
      $(call toolchain,$(USER)," \
        cd $(SRC_DIR)/; \
        gcc hello.c -o $(OUT_DIR)/hello
      ")
    ```

7. Define a release target for your project depending on manifest.txt

    ```
    .PHONY: release
    release: $(OUT_DIR)/hello $(OUT_DIR)/manifest.txt
    	mkdir -p $(RELEASE_DIR)
    	cp $(OUT_DIR)/hello $(RELEASE_DIR)/hello
    	cp $(OUT_DIR)/release.env $(RELEASE_DIR)/release.env
    	cp $(OUT_DIR)/manifest.txt $(RELEASE_DIR)/manifest.txt
    ```

    Note that manifest.txt is optional, but it makes for an ideal single file
    to sign if a release will contain more than one artifact.


## Usage ##

### Build a new release

```
make VERSION=1.0.0rc1 release
```

### Reproduce an existing release

```
make VERSION=1.0.0rc1 attest
```

### Sign an existing release

```
make VERSION=1.0.0rc1 sign
```
