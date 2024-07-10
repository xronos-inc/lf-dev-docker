# SPDX-FileCopyrightText: © 2024 Xronos Inc.
# SPDX-License-Identifier: BSD-3-Clause

##################
## global arguments
##################

# image from which all other stages derive
ARG BASEIMAGE=ubuntu:22.04

# Where possible, packages are installed in user mode.
# This is the user for which user packages are installed
# and the entrypoint is run.
ARG CONTAINER_USER=ubuntu
ARG CONTAINER_USER_UID=1000

# Install Oracle JDK instead of openjdk?
# If Oracle JDK is not available for the platform, 
# openjdk is installed as a fallback.
ARG USE_ORACLE_JDK=true


##################
## OS base stage
##################

# derive from the appropriate base image depending on architecture
FROM --platform=linux/amd64 ${BASEIMAGE} AS base-amd64
FROM --platform=linux/arm64 ${BASEIMAGE} AS base-arm64
FROM --platform=linux/arm/v7 ${BASEIMAGE} AS base-arm
FROM --platform=linux/riscv64 riscv64/${BASEIMAGE} AS base-riscv64
FROM scratch


##################
## dependencies stage
##################
# this stage installs all system dependencies as the root user
FROM base-${TARGETARCH} AS base-dependencies
ARG USE_ORACLE_JDK
ARG CONTAINER_USER
ARG CONTAINER_USER_UID
USER root

# Preconfigure debconf for non-interactive installation - otherwise complains about terminal
# Avoid ERROR: invoke-rc.d: policy-rc.d denied execution of start.
ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY localhost:0.0
RUN echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections
RUN dpkg-divert --local --rename --add /sbin/initctl
RUN ln -sf /bin/true /sbin/initctl
RUN echo "#!/bin/sh\nexit 0" > /usr/sbin/policy-rc.d

# configure apt
RUN apt-get update -q
RUN apt-get install --no-install-recommends -y -q apt-utils 2>&1 \
	| grep -v "debconf: delaying package configuration"
RUN apt-get install --no-install-recommends -y -q \
    ca-certificates \
    apt-transport-https \
    gpg \
    gpg-agent \
    dirmngr \
    lsb-release \
    curl \
    nano \
    jq

# configure locales
RUN apt-get install --no-install-recommends -y -q locales
RUN locale-gen --purge en_US.UTF-8
RUN echo -e 'LANG="en_US.UTF-8"\nLANGUAGE="en_US:en"\n' > /etc/default/locale

# C / C++ and CMake
RUN apt-get install --no-install-recommends -y -q \
    build-essential \
    gcc \
    cmake
RUN gcc --version

# system python
ENV PYTHONDONTWRITEBYTECODE=1
RUN apt-get install --no-install-recommends -y -q \
    python3-dev \
    python3-pip \
    python3-venv
RUN python3 -m pip install --no-warn-script-location --upgrade --user \
    pip \
    setuptools
RUN pip3 install --no-warn-script-location --upgrade --user \
    virtualenv \
    pylint
RUN update-alternatives --install /usr/bin/python python /usr/bin/python3 1
RUN python --version

# git
RUN apt-get install --no-install-recommends -y -q \
    git

# lfc, lingo and python dependencies
RUN apt-get install --no-install-recommends -y -q \
    libssl-dev \
    libffi-dev \
    pkg-config

# openssh server (for remote development)
RUN apt-get install --no-install-recommends -y -q \
    openssh-server

# apt cleanup
RUN apt-get autoremove -y -q
RUN apt-get clean -y -q
RUN rm -rf /var/lib/apt/lists/*

# add the container user and create a cache directory with appropriate permissions
RUN adduser --disabled-password --gecos "" --uid ${CONTAINER_USER_UID} ${CONTAINER_USER}
RUN mkdir -p /var/cache/lf-lang
RUN chown ${CONTAINER_USER}:${CONTAINER_USER} /var/cache/lf-lang

# run subsequent commands as container user
USER ${CONTAINER_USER}
# ensure .local/bin is in PATH
RUN mkdir -p /home/${CONTAINER_USER}/.local/bin
ENV PATH="${PATH}:/home/${CONTAINER_USER}/.local/bin"
# setup .ssh server
RUN mkdir -p /home/${CONTAINER_USER}/.ssh
RUN touch /home/${CONTAINER_USER}/.ssh/authorized_keys
RUN chmod 600 /home/${CONTAINER_USER}/.ssh/authorized_keys


####################
#  system RTI stage
####################
# see https://github.com/lf-lang/reactor-c/tree/main/core/federated/RTI
# produces artifact /usr/local/bin/RTI which is a standalone application
FROM base-dependencies as rti
ARG CONTAINER_USER
USER root
# clone lingua-franca with release tag to ensure RTI matches the LFC install
RUN git clone \
    -c advice.detachedHead=false \
    --branch $(curl -s https://api.github.com/repos/lf-lang/lingua-franca/releases/latest | jq -r '.tag_name') \
    --single-branch \
    --recurse-submodules \
    --depth 1 \
    https://github.com/lf-lang/lingua-franca \
    /var/cache/lf-lang/lingua-franca
RUN mkdir -p /var/cache/lf-lang/lingua-franca/core/src/main/resources/lib/c/reactor-c/core/federated/RTI/build
RUN (cd /var/cache/lf-lang/lingua-franca/core/src/main/resources/lib/c/reactor-c/core/federated/RTI/build && cmake -DAUTH=on ..)
RUN (cd /var/cache/lf-lang/lingua-franca/core/src/main/resources/lib/c/reactor-c/core/federated/RTI/build && make)
RUN (cd /var/cache/lf-lang/lingua-franca/core/src/main/resources/lib/c/reactor-c/core/federated/RTI/build && make install)
RUN rm -rf /var/cache/lf-lang/lingua-franca
# verify RTI is available to container user
USER ${CONTAINER_USER}
# RTI doesn't have a --version flag
RUN which RTI


####################
#  system Java stage
####################
FROM base-dependencies as java
ARG ${CONTAINER_USER}
USER root
# set up repositories for Oracle (but install only if USE_ORACLE_JDK is true)
RUN mkdir -p /usr/share/keyrings/
RUN gpg --recv-keys --keyserver keyserver.ubuntu.com EA8CACC073C3DB2A
RUN gpg --export EA8CACC073C3DB2A | tee /usr/share/keyrings/linuxuprising-java.gpg
RUN echo "deb [signed-by=/usr/share/keyrings/linuxuprising-java.gpg] http://ppa.launchpad.net/linuxuprising/java/ubuntu $(lsb_release --codename --short) main" \
    | tee /etc/apt/sources.list.d/linuxuprising-java.list
RUN echo oracle-java17-installer shared/accepted-oracle-license-v1-3 select true \
    | /usr/bin/debconf-set-selections
RUN apt-get update -q
# install JDK
RUN if ${USE_ORACLE_JDK} && [ "$(uname -m)" != "armv7l" ] && [ "$(uname -m)" != "riscv64" ]; then \
      apt-get install --no-install-recommends -y -q \
        oracle-java17-installer \
        oracle-java17-set-default \
    ; else apt-get install --no-install-recommends -y -q \
        openjdk-17-jdk \
    ; fi
# apt cleanup
RUN apt-get autoremove -y -q
RUN apt-get clean -y -q
RUN rm -rf /var/lib/apt/lists/*
# verify java is available to container user
USER ${CONTAINER_USER}
RUN java --version


####################
# user lfc stage
####################
FROM java as lfc
ARG CONTAINER_USER
USER ${CONTAINER_USER}
RUN curl -Ls https://install.lf-lang.org | bash -s cli
RUN lfc --version


####################
# user rust stage
####################
FROM base-dependencies as rust
ARG CONTAINER_USER
USER ${CONTAINER_USER}
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | bash -s -- -y
ENV PATH="${PATH}:/home/${CONTAINER_USER}/.cargo/bin"
RUN rustc --version


#####################
# user Lingo stage
#####################
FROM rust as lingo
ARG CONTAINER_USER
USER ${CONTAINER_USER}
RUN mkdir -p /var/cache/lf-lang/lingo
RUN chown ${CONTAINER_USER}:${CONTAINER_USER} /var/cache/lf-lang/lingo
# get latest release tag and save to /var/cache/lf-lang/lingo-version
RUN git ls-remote --refs --sort='version:refname' \
    --tags https://github.com/lf-lang/lingo \
    | cut -d/ -f3- \
    | tail -n1 \
    > /var/cache/lf-lang/lingo-version
# pull latest release tag
RUN git clone \
    -c advice.detachedHead=false \
    --single-branch \
    --depth 1 \
    --branch $(cat /var/cache/lf-lang/lingo-version) \
    https://github.com/lf-lang/lingo \
    /var/cache/lf-lang/lingo
# install lingo and cleanup
RUN /home/${CONTAINER_USER}/.cargo/bin/cargo install --path /var/cache/lf-lang/lingo
RUN rm -rf /var/cache/lf-lang/lingo
RUN lingo --version


####################
## application stage
####################
FROM base-${TARGETARCH} as app
LABEL maintainer="xronos-inc"
LABEL source="https://github.com/xronos-inc/lf-dev-docker"
ARG CONTAINER_USER
USER ${CONTAINER_USER}

EXPOSE 22

# copy from previous build stages
COPY --from=java   / /
COPY --from=rti    /usr/local/bin/RTI /usr/local/bin/RTI
COPY --from=lfc    /home/${CONTAINER_USER}/.local/bin /home/${CONTAINER_USER}/.local/bin
COPY --from=lfc    /home/${CONTAINER_USER}/.local/share/lingua-franca /home/${CONTAINER_USER}/.local/share/lingua-franca
COPY --from=rust   /home/${CONTAINER_USER}/.cargo /home/${CONTAINER_USER}/.cargo
COPY --from=rust   /home/${CONTAINER_USER}/.rustup /home/${CONTAINER_USER}/.rustup
COPY --from=lingo  /home/${CONTAINER_USER}/.cargo/bin /home/${CONTAINER_USER}/.cargo/bin

# configure rust environment variables
ENV PATH="${PATH}:/home/${CONTAINER_USER}/.cargo/bin"
RUN echo PATH="\${PATH}:/home/${CONTAINER_USER}/.cargo/bin" >> /home/${CONTAINER_USER}/.bashrc

# configure lfc environment variables
ENV PATH=${PATH}:/home/${CONTAINER_USER}/.local/bin
RUN echo PATH="\${PATH}:/home/${CONTAINER_USER}/.local/bin" >> /home/${CONTAINER_USER}/.bashrc

# test all packages
RUN gcc --version \
    && g++ --version \
    && make --version \
    && cmake --version \
    && python --version \
    && rustc --version \
    && cargo --version \
    && lfc --version \
    && lingo --version \
    && which RTI
    # RTI does not have a --version flag, so simply test it is in the system path

ENTRYPOINT ["lfc"]
