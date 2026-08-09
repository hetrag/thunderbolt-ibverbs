%global modname thunderbolt-ibverbs
%global kver @KVER@

Name:           %{modname}-kmod-@KVER_PKG@
Version:        @VERSION@
Release:        1%{?dist}
Summary:        Thunderbolt/USB4 host-to-host RDMA verbs kernel module for %{kver}

License:        GPL-2.0-only
URL:            https://github.com/hellas-ai/thunderbolt-ibverbs

BuildArch:      x86_64
# Distro kernels provide `kernel-uname-r = <release>`; kernels packaged by the
# kernel's own `make binrpm-pkg` provide the bare name `kernel-<release>`
# instead (and a release with two hyphens isn't even a legal rpm version), so
# the builder substitutes whichever form applies.
Requires:       @KERNEL_REQ@
Requires(post): kmod
Requires(postun): kmod
Provides:       %{modname}-kmod = %{version}-%{release}
Conflicts:      %{modname}-dkms

# The .ko is prebuilt against a specific kernel; do not let rpm generate
# kernel(symbol) deps or try to strip/debuginfo-split it.
%global __requires_exclude ^kernel\\(.*\\)$
%global debug_package %{nil}
%global __strip /bin/true

%description
Prebuilt thunderbolt_ibverbs.ko matched against kernel %{kver}. Exposes an RDMA
verbs device over Thunderbolt/USB4 host-to-host links. Install alongside
usb4-rdma-provider for ibv_devices visibility.

This package is the binary alternative to %{modname}-dkms: it needs no compiler
on the target host but only works with the exact kernel it was built for.

%install
install -d -m 0755 %{buildroot}/lib/modules/%{kver}/extra
install -m 0644 %{_sourcedir}/thunderbolt_ibverbs.ko \
    %{buildroot}/lib/modules/%{kver}/extra/thunderbolt_ibverbs.ko

%post
/sbin/depmod -a %{kver} >/dev/null 2>&1 || :

%postun
if [ "$1" = "0" ]; then
    /sbin/depmod -a %{kver} >/dev/null 2>&1 || :
fi

%files
%dir /lib/modules/%{kver}/extra
/lib/modules/%{kver}/extra/thunderbolt_ibverbs.ko

%changelog
* Sun Aug 09 2026 thunderbolt-ibverbs packaging <george@hellas.ai> - 0.3.4-1
- Initial kernel-matched binary kmod package, produced by
  tools/fedora-rpm-stack.sh.
