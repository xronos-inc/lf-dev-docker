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
# Install TypeScript packages
ARG INSTALL_TYPESCRIPT=true


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
## system dependencies stage
##################
# this stage installs all system dependencies as the root user
FROM base-${TARGETARCH} AS sys-deps

ARG USE_ORACLE_JDK
ARG INSTALL_TYPESCRIPT

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
    pkg-config \
    lsb-release \
    gpg \
    gpg-agent \
    dirmngr \
    curl \
    wget

# configure locales
RUN apt-get install --no-install-recommends -y -q locales
RUN locale-gen --purge en_US.UTF-8
RUN echo -e 'LANG="en_US.UTF-8"\nLANGUAGE="en_US:en"\n' > /etc/default/locale

# C / C++ and CMake
RUN apt-get install --no-install-recommends -y -q \
    build-essential \
    gcc \
    cmake

# system python
ENV PYTHONDONTWRITEBYTECODE=1
RUN apt-get update -y -q
RUN apt-get install --no-install-recommends -y -q \
    python3-dev \
    python3-pip \
    python3-venv

# git
RUN apt-get install --no-install-recommends -y -q \
    git

# LF & RTI depencencies
RUN apt-get install --no-install-recommends -y -q \
    libssl-dev \
    libffi-dev

# java
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

# TypeScript
RUN if ${INSTALL_TYPESCRIPT} && [ "$(uname -m)" != "riscv64" ]; then \
    apt-get install --no-install-recommends -y -q  \
        nodejs \
        npm \
        node-typescript; \
    fi

# apt cleanup
RUN apt-get autoremove -y -q
RUN apt-get clean -y -q
RUN rm -rf /var/lib/apt/lists/*

# create cache directory used by later stages
RUN mkdir -p /var/cache/lf-lang


####################
#  RTI stage
####################
# see https://github.com/lf-lang/reactor-c/tree/main/core/federated/RTI
# produces artifact /usr/local/bin/RTI which is a standalone application
FROM sys-deps as rti
USER root
RUN git clone \
    --single-branch \
    --depth 1 \
    https://github.com/lf-lang/reactor-c \
    /var/cache/lf-lang/reactor-c
RUN mkdir -p /var/cache/lf-lang/reactor-c/core/federated/RTI/build
RUN (cd /var/cache/lf-lang/reactor-c/core/federated/RTI/build && cmake -DAUTH=on ..)
RUN (cd /var/cache/lf-lang/reactor-c/core/federated/RTI/build && make)
RUN (cd /var/cache/lf-lang/reactor-c/core/federated/RTI/build && make install)
RUN rm -rf /var/cache/lf-lang/reactor-c


####################
# user dependencies stage
####################
# this stage installs user dependencies for the container user
# user install stages should derive from this container
FROM sys-deps as user-deps

ARG CONTAINER_USER
ARG CONTAINER_USER_UID

# add the container user and create a cache directory with appropriate permissions
USER root
RUN adduser --disabled-password --gecos "" --uid ${CONTAINER_USER_UID} ${CONTAINER_USER}
RUN mkdir -p /var/cache/lf-lang
RUN chown ${CONTAINER_USER}:${CONTAINER_USER} /var/cache/lf-lang

# run subsequent commands as container user
USER ${CONTAINER_USER}

# install python dependencies
ENV PYTHONDONTWRITEBYTECODE=1
RUN pip3 install --no-warn-script-location --upgrade --user \
    pip \
    setuptools
RUN pip3 install --no-warn-script-location --upgrade --user \
    virtualenv \
    pylint

# ensure .local/bin is in PATH
RUN mkdir -p /home/${CONTAINER_USER}/.local/bin
ENV PATH="${PATH}:/home/${CONTAINER_USER}/.local/bin"
RUN echo "export PATH=${PATH}:/home/${CONTAINER_USER}/.local/bin" >> /home/${CONTAINER_USER}/.bashrc


####################
# user rust stage
####################
FROM user-deps as rust
ARG CONTAINER_USER
USER ${CONTAINER_USER}
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | bash -s -- -y
ENV PATH="${PATH}:/home/${CONTAINER_USER}/.cargo/bin"


####################
# user LFC stage
####################
FROM user-deps as lfc
ARG CONTAINER_USER
USER ${CONTAINER_USER}
RUN curl -Ls https://install.lf-lang.org | bash -s cli
 

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
    --single-branch \
    --depth 1 \
    --branch $(cat /var/cache/lf-lang/lingo-version) \
    https://github.com/lf-lang/lingo \
    /var/cache/lf-lang/lingo
# install lingo and cleanup
RUN /home/${CONTAINER_USER}/.cargo/bin/cargo install --path /var/cache/lf-lang/lingo
RUN rm -rf /var/cache/lf-lang/lingo


####################
## test stages
####################
FROM sys-deps as test-gcc
RUN gcc --version > /var/cache/lf-lang/gcc-version

FROM sys-deps as test-java
RUN java --version > /var/cache/lf-lang/java-version

FROM sys-deps as test-ts
RUN if $(which tsc); then \
        tsc --version > /var/cache/lf-lang/tsc-version; \
    else touch /var/cache/lf-lang/tsc-version; \
    fi

FROM user-deps as test-python
RUN python3 --version > /var/cache/lf-lang/python-version

FROM rust as test-rust
RUN rustc --version > /var/cache/lf-lang/rustc-version

FROM lfc as test-lfc
RUN lfc --version > /var/cache/lf-lang/lfc-version

FROM lingo as test-lingo
RUN lingo --version > /var/cache/lf-lang/lingo-version


####################
## application stage
####################
FROM base-${TARGETARCH} as app
LABEL maintainer="xronos-inc"
LABEL source="https://github.com/xronos-inc/lfc-remote-ssh"
ARG CONTAINER_USER
USER ${CONTAINER_USER}

# copy output from previous test stages to enforce they are built and run
COPY --from=test-gcc      /var/cache/lf-lang/gcc-version     /var/cache/lf-lang/gcc-version
COPY --from=test-java     /var/cache/lf-lang/java-version    /var/cache/lf-lang/java-version
COPY --from=test-ts       /var/cache/lf-lang/tsc-version     /var/cache/lf-lang/tsc-version
COPY --from=test-python   /var/cache/lf-lang/python-version  /var/cache/lf-lang/python-version
COPY --from=test-rust     /var/cache/lf-lang/rustc-version   /var/cache/lf-lang/rustc-version
COPY --from=test-lfc      /var/cache/lf-lang/lfc-version     /var/cache/lf-lang/lfc-version
COPY --from=test-lingo    /var/cache/lf-lang/lingo-version   /var/cache/lf-lang/lingo-version

# copy from previous build stages
COPY --from=user-deps / /
COPY --from=rti /usr/local/bin/RTI /usr/local/bin/RTI
COPY --from=rust /home/${CONTAINER_USER}/.cargo/bin /home/${CONTAINER_USER}/.cargo/bin
COPY --from=lfc /home/${CONTAINER_USER}/.local/bin /home/${CONTAINER_USER}/.local/bin
COPY --from=lfc /home/${CONTAINER_USER}/.local/share/lingua-franca /home/${CONTAINER_USER}/.local/share/lingua-franca
COPY --from=lingo /home/${CONTAINER_USER}/.cargo/bin /home/${CONTAINER_USER}/.cargo/bin

ENTRYPOINT ["lfc"]