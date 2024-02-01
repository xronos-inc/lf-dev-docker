# Build a docker image containing the latest Lingua Franca tools

## Description

Dockerfile for Lingua Franca, Lingo and all supported programming languages. This dockerfile installs:
- lfc compiler (user install)
- lingo package manager (user install)
- C RTI
- gcc and g++
- Oracle Java 17 or openjdk
- TypeScript and npm package manager
- python3 (packages installed as user install)
- rust (user install)

## Platform support
This dockerfile builds for:
- linux/amd64
- linux/arm64
- linux/arm/v7
- - Oracle JDK not supported
- linux/riscv64
- - Oracle JDK not supported
- - TypeScript not supported

## Prerequisites
- docker

## Build and run the image

```shell
docker build . -t mylfc
```

Run the image with the `--version` flag (equivalent to `lfc --version`):
```shell
docker run -it --tty --rm mylfc --version
```

The lfc compiler is the default entrypoint. Any additional arguments from the docker run command will be passed to the compiler. Alternately add the flag `--entrypoint /bin/bash` to open an interactive shell.

## Arguments

The following command-line arguments may be passed into the build command:
- `BASEIMAGE` (`=ubuntu:22.04`) the parent image for the build. Must have apt-get available.
- `USE_ORACLE_JDK` (`=true`) use the Oracle JDK; otherwise use openjdk. linux/arm/v7 does not support Orackle JDK and ignores this flag.
- `INSTALL_TYPESCRIPT` (`=true`) install TypeScript packages.
- `CONTAINER_USER` (`=ubuntu`) the username of the user for local package installs and to run entrypoint commands.
- `CONTAINER_USER_UID` (`=1000`) the UID of the container user.


## Multiarch build

