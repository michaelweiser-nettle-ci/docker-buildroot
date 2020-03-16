FROM debian:buster AS build

ARG BR_ARCH=armv5b
ARG BR_RELEASE=2020.02
ARG BR_LIBC=uclibc

MAINTAINER Michael Weiser <michael.weiser@gmx.de>

RUN apt-get update -qq -y && \
	apt-get dist-upgrade -y && \
	apt-get autoremove -y && \
	apt-get install -y cpio dash bc bzip2 file g++ make patch perl python \
		rsync unzip wget && \
	apt-get clean all && \
	rm -rf /var/lib/apt/lists/*

# buildroot (or some of its packages at least) do not want to be built as root
RUN useradd -d /buildroot -m buildroot
USER buildroot
WORKDIR /buildroot

# plain HTTP to allow caching, verification necessary anyway
COPY buildroot-*.tar.bz2.sha256sum /buildroot/
RUN br_archive=buildroot-${BR_RELEASE}.tar.bz2 && \
	wget http://buildroot.org/downloads/${br_archive} && \
		sha256sum -c ${br_archive}.sha256sum && \
		tar -xf ${br_archive} --strip-components=1 && \
		rm -f ${br_archive}

# - we include the arch version in GNU_TARGET_NAME because default optimisation
#   is derived from it
# - 2020.02 supports toplevel parallel make, giving an about 25% speedup by
#   running multiple downloads, configures and builds in parallel
# - we need to explicitly allow relative paths in LD_LIBRARY_PATH with uClibc
# - apart from prefixing their names we also unset generic build arg
#   environment variables for good measure because e.g. python's configure picks
#   up LIBC
# - force 4.19 kernel headers to avoid error "kernel too old" on GitLab CI
RUN br_arch="${BR_ARCH}" ; br_libc="${BR_LIBC}" ; \
	unset BR_ARCH BR_LIBC BR_RELEASE ; \
	cpuopt=$(echo "${br_arch}" | sed \
		-e 's/^armv5b$/arm926t/' \
		-e 's/^armv6b$/arm1136j_s/' \
		-e 's/^armv7b$/cortex_a7/' \
	) && \
	libcopt="$(echo "${br_libc}" | tr '[a-z]' '[A-Z]')" && \
	( \
		echo 'BR2_armeb=y' ; \
		echo "BR2_${cpuopt}=y" ; \
		echo 'BR2_TOOLCHAIN_BUILDROOT_CXX=y' ; \
		echo "BR2_TOOLCHAIN_BUILDROOT_${libcopt}=y" ; \
		echo 'BR2_KERNEL_HEADERS_4_19=y' ; \
		echo 'BR2_PACKAGE_GMP=y' ; \
		echo 'BR2_PER_PACKAGE_DIRECTORIES=y' ; \
	) > .config && \
	echo LDSO_SAFE_RUNPATH=n >> package/uclibc/uClibc-ng.config && \
	make olddefconfig && \
	triple="$(make printvars VARS=GNU_TARGET_NAME | \
		sed -e "s,.*=armeb-,${br_arch}-,")" && \
	echo "${triple}" > triple && \
	make -s -j$(nproc) GNU_TARGET_NAME="$triple" && \
	rm -rf output/build output/per-package dl
	# no more stuff here so errors do not make us loose the build

# - we create a dummy ld.so.cache to stop glibc's ld.so from segfaulting
#   because of endianness differences:
#   https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=731082. Fortunately, qemu
#   will redirect file operations to the ld prefix if the file in question
#   exists there. (We do not use --inhibit-cache because uClibc's ld.so does
#   not support it.)
# - generate a qemu wrapper to simplify use with the cpu forced to the right
#   architecture to show up runtime problems through SIGILL
RUN triple="$(cat triple)" && \
	sysroot="/buildroot/output/host/${triple}/sysroot" && \
	touch "${sysroot}"/etc/ld.so.cache && \
	qemucpu=$(echo "${BR_ARCH}" | sed \
		-e 's/^armv5b$/arm926/' \
		-e 's/^armv6b$/arm1136/' \
		-e 's/^armv7b$/cortex-a7/' \
	) && \
	( echo '#!/bin/dash' ; \
		echo "exec qemu-armeb -cpu '${qemucpu}' -L '${sysroot}'" \
			'-E LD_LIBRARY_PATH="${LD_LIBRARY_PATH}" "$@"' ; \
	) > qemu && \
	chmod 755 qemu

FROM debian:buster

MAINTAINER Michael Weiser <michael.weiser@gmx.de>

# buildroot toolchain brings autoconf, automake, libtool, bison and m4 but
# autoconf/automake have some unresolved perl module dependencies
RUN apt-get update -qq -y && \
	apt-get dist-upgrade -y && \
	apt-get autoremove -y && \
	apt-get install -y autoconf dash g++ make qemu-user && \
	apt-get clean all && \
	rm -rf /var/lib/apt/lists/*

# copy over only the toolchain, nothing else is needed, contains a sysroot with
# enough of our dependencies to run the testsuite against
COPY --from=build /buildroot/output/host /buildroot/output/host
COPY --from=build /buildroot/qemu /buildroot/triple /buildroot/

# put toolchain last in path to prefer host tools (autoconf)
ENV PATH=/usr/sbin:/usr/bin:/sbin:/bin:/buildroot/output/host/bin
