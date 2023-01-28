# Toolchain #

<https://codeberg.org/distrust/toolchain>

## About ##

A library of opinionated make functions targeting projects that either need
deterministic builds, or a shared deterministic toolchain shared across all
who use a project.

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

## Build ##

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
