# Docker image with the latest Lingua Franca tools

Dockerfile used to build [xronosinc/lf](https://hub.docker.com/repository/docker/xronosinc/lf) docker image.


## Description

Dockerfile for Lingua Franca development tools. This dockerfile installs:
- lfc compiler (user install)
- lingo package manager (user install)
- Oracle Java 17 or openjdk
- C RTI
- gcc, g++ and cmake
- python3
- rust (user install)


## Platform support
This dockerfile builds for:
- linux/amd64
- linux/arm64
- linux/arm/v7
- - Oracle JDK not supported (openjdk used instead)
- linux/riscv64
- - Oracle JDK not supported (openjdk used instead)


## Prerequisites
- docker


## Build and run the image

```shell
docker build . -t xronosinc/lf:latest
```

Run the image with the `--version` flag (equivalent to `lfc --version`):
```shell
docker run -it --tty --rm xronosinc/lf:latest --version
```

The lfc compiler is the default entrypoint. Any additional arguments from the docker run command will be passed to the compiler. Alternately add the flag `--entrypoint /bin/bash` to open an interactive shell.


## Develop using VS Code and Remote SSH

You can connect to the container and develop using VS Code on your host system. You'll need to use an SSH key to establish a connection to the container.

```shell
docker run --name lf -p 2222:22 --interactive --tty --detach --user root --entrypoint /usr/sbin/sshd xronosinc/lf:latest -D
docker exec -it lf sh -c "echo $(cat ~/.ssh/id_rsa.pub) >> /home/ubuntu/.ssh/authorized_keys"
```

You may want to map local volume which contains your source code repositories into the container. Add flag `-v /path/to/local/code:/home/ubuntu/code` to the `docker run` command above.

SSH into the container:
```shell
ssh -p 2222 ubuntu@localhost
```

You may query the IP address of the docker container with
```shell
docker inspect --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' lf
```

Once the container is started, connect to the remote target from VS Code on your host. See [Remote Development](https://code.visualstudio.com/docs/remote/ssh) for more information.


## Arguments

The following command-line arguments may be passed into the build command:
- `BASEIMAGE` (`=ubuntu:22.04`) the parent image for the build. Must have apt-get available.
- `USE_ORACLE_JDK` (`=true`) use the Oracle JDK; otherwise use openjdk. linux/arm/v7 does not support Orackle JDK and ignores this flag.
- `CONTAINER_USER` (`=ubuntu`) the username of the user for local package installs and to run entrypoint commands.
- `CONTAINER_USER_UID` (`=1000`) the UID of the container user.


## Multiarch build

Build for multiple architectures using the [buildx](https://docs.docker.com/buildx/working-with-buildx/) command.

```shell
docker buildx build . --tag xronosinc/lf:latest --platform linux/amd64,linux/arm64,linux/arm/v7,linux/riscv64
```

_Note, these builds are quite slow and may require a powerful system. Docker can easily eat up system resources and stall on a slow machine._
