%global toolprefix usb4_
%global perftest_prefix %{_libexecdir}/usb4-perftest

Name:           usb4-perftest
Version:        @PERFTEST_VERSION@
Release:        1%{?dist}
Summary:        perftest built for usb4_rdma Thunderbolt/USB4 RDMA devices

License:        BSD-2-Clause OR GPL-2.0-only
URL:            https://github.com/linux-rdma/perftest
Source0:        perftest-%{version}.tar.gz

BuildRequires:  autoconf
BuildRequires:  automake
BuildRequires:  gcc
BuildRequires:  libtool
BuildRequires:  libibumad-devel
BuildRequires:  librdmacm-devel
BuildRequires:  make
BuildRequires:  pciutils-devel
BuildRequires:  rdma-core-devel

Requires:       libibverbs
Recommends:     usb4-rdma-provider

%description
The linux-rdma perftest suite, rebuilt so it interoperates with the
thunderbolt_ibverbs / usb4_rdma stack:

  * mlx5 direct-verbs support is forced off. With MLX5DV enabled the perftest
    connection-negotiation struct grows by 8 bytes, which breaks the on-wire
    exchange against peers built without mlx5dv.h (notably the macOS build
    against Apple's RDMA SDK). usb4_rdma devices are not Mellanox, so nothing
    is lost.
  * extended-CQ, CUDA, ROCm and Neuron backends are disabled; the usb4_rdma
    provider implements none of them.

Installed under %{perftest_prefix} with %{toolprefix}-prefixed symlinks in
%{_bindir}, so this package coexists with Fedora's stock perftest instead of
replacing it. Point the benchmark runner at it with
TBV_PERFTEST=%{perftest_prefix}.

%prep
%autosetup -n perftest-%{version}

# Mirror the flake's postPatch: pin MLX5DV off at configure time.
sed -i 's/\[HAVE_MLX5DV=yes\], \[HAVE_MLX5DV=no\])/[HAVE_MLX5DV=no], [HAVE_MLX5DV=no])/' \
    configure.ac
grep -q 'HAVE_MLX5DV=yes' configure.ac && exit 1
./autogen.sh

%build
%configure \
    --prefix=%{perftest_prefix} \
    --bindir=%{perftest_prefix}/bin \
    --mandir=%{perftest_prefix}/share/man \
    --disable-cudart \
    --disable-rocm \
    --disable-neuron \
    --disable-cq_ex
%make_build

%install
%make_install

# Prefixed symlinks so the usb4 build is reachable on PATH without colliding
# with the stock perftest package's /usr/bin/ib_* binaries.
install -d -m 0755 %{buildroot}%{_bindir}
for tool in %{buildroot}%{perftest_prefix}/bin/*; do
    name="$(basename "$tool")"
    ln -s %{perftest_prefix}/bin/"$name" \
        %{buildroot}%{_bindir}/%{toolprefix}"$name"
done

%files
%license COPYING
%doc README
%dir %{perftest_prefix}
%dir %{perftest_prefix}/bin
%{perftest_prefix}/bin/*
%{perftest_prefix}/share/man/man1/*
%{_bindir}/%{toolprefix}*

%changelog
* Sun Aug 09 2026 thunderbolt-ibverbs packaging <george@hellas.ai> - 26.04.17-1
- Initial usb4_rdma-targeted perftest build, mirroring nix/perftest.nix.
  Produced by tools/fedora-rpm-stack.sh.
