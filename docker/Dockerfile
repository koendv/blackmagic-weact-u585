# Build environment for the WeAct Black Pill STM32U585 Black Magic Debug firmware and bmpflash.
#
# Ubuntu 22.04 keeps the glibc requirement of the Linux bmpflash binary low (glibc 2.35).
FROM ubuntu:22.04

ARG ARM_TOOLCHAIN_VERSION=15.2.rel1
ARG MESON_VERSION=1.6.1

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
	&& apt-get install -y --no-install-recommends \
		ca-certificates \
		curl \
		file \
		g++ \
		g++-mingw-w64-x86-64 \
		git \
		ninja-build \
		pkg-config \
		python3 \
		python3-pip \
		xz-utils \
	&& rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache-dir "meson==${MESON_VERSION}"

# The same Arm GNU toolchain release upstream Black Magic Debug CI uses. Its SHA256 is printed, not checked;
# compare it with Arm's published .sha256asc (15.2.rel1: 597893282ac8c6ab1a4073977f2362990184599643b4c5ee34870a8215783a16)
RUN curl -fsSL -o /tmp/arm-gnu-toolchain.tar.xz \
		"https://developer.arm.com/-/media/Files/downloads/gnu/${ARM_TOOLCHAIN_VERSION}/binrel/arm-gnu-toolchain-${ARM_TOOLCHAIN_VERSION}-x86_64-arm-none-eabi.tar.xz" \
	&& echo "Arm GNU toolchain ${ARM_TOOLCHAIN_VERSION} SHA256: $(sha256sum /tmp/arm-gnu-toolchain.tar.xz | cut -d' ' -f1)" \
	&& tar -xJf /tmp/arm-gnu-toolchain.tar.xz -C /opt \
	&& rm /tmp/arm-gnu-toolchain.tar.xz \
	&& ln -s /opt/arm-gnu-toolchain-*-arm-none-eabi /opt/arm-none-eabi

ENV PATH=/opt/arm-none-eabi/bin:${PATH}
