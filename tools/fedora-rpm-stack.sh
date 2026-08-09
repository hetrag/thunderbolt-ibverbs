#!/usr/bin/env bash
# Build the full Fedora RPM stack for thunderbolt-ibverbs on the local machine:
#
#   1. kernel      Linux 7.2 + the kernel-workflow/patches Thunderbolt series,
#                  configured from the running system's config, packaged with
#                  the kernel's own `make binrpm-pkg`.
#   2. module      thunderbolt_ibverbs.ko built against *that* kernel and
#                  packaged as a kernel-matched binary kmod RPM.
#   3. provider    usb4_rdma libibverbs provider built against the rdma-core
#                  version Fedora actually ships (so the PABI suffix and the
#                  libibverbs ABI match the stock libibverbs).
#   4. perftest    the linux-rdma perftest suite rebuilt with MLX5DV and the
#                  extended-CQ/accelerator backends off, so it actually works
#                  against usb4_rdma devices and stays wire-compatible with the
#                  macOS perftest build.
#
# Nothing here installs into the running system; artefacts land in OUT_DIR.
#
# Only the deps install step and the provider step need root; they use sudo
# on demand, so run this as your normal user.

set -euo pipefail

repo_root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
	cat <<'EOF'
Usage:
  tools/fedora-rpm-stack.sh [all|kernel|module|provider|perftest]...

Stages:
  kernel     Patch + build the kernel and produce kernel / kernel-devel RPMs.
  module     Build thunderbolt_ibverbs.ko against that kernel, produce a kmod RPM.
  provider   Build the usb4_rdma libibverbs provider RPM against Fedora's
             rdma-core version.
  perftest   Build the usb4_rdma-compatible perftest RPM.
  all        kernel + module + provider + perftest (default).

Environment:
  KERNEL_SRC     Kernel git tree (default $HOME/git/thunderbolt).
  KERNEL_REF     Ref to build from (default origin/master, westeri's mainline
                 mirror). Do NOT use the thunderbolt-for-vX.Y-rcN tags: they
                 name the merge window they target, not their base, so they
                 build a stale base kernel. `origin/next` is likewise many
                 -rc's behind mainline.
  KERNEL_FETCH   1 to `git fetch --tags` before building (default 1).
  KERNEL_CONFIG  Config to seed from (default newest /boot/config-*).
  LOCALVERSION   CONFIG_LOCALVERSION value (default -tbv).
  KERNEL_DEBUG_INFO  1 to keep DWARF/BTF debug info (default 0; much faster).
  KVER           Skip the kernel stage and build the module against this
                 already-installed kernel (uses /usr/src/kernels/$KVER).
  RDMA_CORE_TAG  rdma-core git tag (default: derived from Fedora's rdma-core).
  PERFTEST_TAG   linux-rdma/perftest tag to build (default 26.04.17, matching
                 nix/perftest.nix so Linux and macOS builds stay wire-compatible).
  TBV_VERSION    Package version (default PACKAGE_VERSION from dkms.conf).
  OUT_DIR        Artefact directory (default $repo/dist).
  JOBS           Parallelism (default nproc).
  SKIP_DEPS      1 to skip the dnf build-dep install (default 0).
  PATCH_SKIP     Space separated patch-file prefixes to skip
                 (default "0006 0010-thunderbolt-trace"; both are superseded
                 upstream and no longer apply to 7.2).
EOF
}

stages=()
for arg in "$@"; do
	case "$arg" in
		-h|--help) usage; exit 0 ;;
		all) stages+=(kernel module provider perftest) ;;
		kernel|module|provider|perftest) stages+=("$arg") ;;
		*) printf 'error: unknown stage: %s\n' "$arg" >&2; usage >&2; exit 1 ;;
	esac
done
[[ ${#stages[@]} -gt 0 ]] || stages=(kernel module provider perftest)

kernel_src="${KERNEL_SRC:-$HOME/git/thunderbolt}"
kernel_ref="${KERNEL_REF:-origin/master}"
kernel_fetch="${KERNEL_FETCH:-1}"
kernel_config="${KERNEL_CONFIG:-$(ls -1v /boot/config-* 2>/dev/null | tail -n 1)}"
localversion="${LOCALVERSION:--tbv}"
keep_debug_info="${KERNEL_DEBUG_INFO:-0}"
version="${TBV_VERSION:-$(awk -F'"' '/^PACKAGE_VERSION=/ { print $2; exit }' "$repo_root/dkms.conf")}"
out_dir="${OUT_DIR:-$repo_root/dist}"
jobs="${JOBS:-$(nproc)}"
skip_deps="${SKIP_DEPS:-0}"
perftest_tag="${PERFTEST_TAG:-26.04.17}"
patch_skip="${PATCH_SKIP:-0006 0010-thunderbolt-trace}"
state_file="$out_dir/.fedora-rpm-stack.kver"

[[ -n "$version" ]] || { printf 'error: could not determine version from dkms.conf\n' >&2; exit 1; }
mkdir -p "$out_dir"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

as_root() {
	if [[ "$(id -u)" -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

install_deps() {
	[[ "$skip_deps" == "1" ]] && return 0
	log "Installing build dependencies"
	as_root dnf install -y -q --setopt=install_weak_deps=False \
		autoconf automake bc bison cmake curl dwarves elfutils-libelf-devel \
		flex gcc gcc-c++ git libcap-devel libibumad-devel libnl3-devel \
		librdmacm-devel libtool make ncurses-devel ninja-build openssl-devel \
		openssl patch patchelf pciutils-devel perl pkgconf python3-docutils \
		python3-pyelftools rdma-core-devel rpm-build rsync systemd-devel tar \
		xz zstd
}

# ---------------------------------------------------------------- kernel ----

kernel_should_skip_patch() {
	local base="$1" skip
	for skip in $patch_skip; do
		[[ "$base" == "$skip"* ]] && return 0
	done
	return 1
}

# Build from westeri's `master` (a mainline mirror), not `next`. The
# thunderbolt-for-vX.Y-rcN tags name the merge window they target, not their
# base -- they are cut from `next`, whose Makefile can sit many -rc's behind
# mainline, which is why they yield stale releases like 7.2.0-rc1. `master`
# already carries every 01xx maintainer patch this repo depends on (ConfigFS,
# USB4STREAM, tb_ring_flush, tb_property_merge_dir); only the handful of
# not-yet-upstream `next` commits are missing, and none are used here.
resolve_kernel_ref() {
	git -C "$kernel_src" rev-parse --git-dir >/dev/null 2>&1 ||
		die "not a git tree: $kernel_src"

	if [[ "$kernel_fetch" == "1" ]]; then
		log "Fetching $kernel_src"
		git -C "$kernel_src" fetch --tags --prune origin ||
			die "git fetch failed in $kernel_src"
	fi

	git -C "$kernel_src" rev-parse -q --verify "${kernel_ref}^{commit}" >/dev/null ||
		die "unknown kernel ref: $kernel_ref"

	local base
	base="$(git -C "$kernel_src" show "$kernel_ref:Makefile" 2>/dev/null |
		awk -F' = ' '
			/^VERSION =/     { v=$2 }
			/^PATCHLEVEL =/  { p=$2 }
			/^SUBLEVEL =/    { s=$2 }
			/^EXTRAVERSION =/{ e=$2 }
			END { printf "%s.%s.%s%s", v, p, s, e }')"
	log "Building from $kernel_ref (base kernel ${base:-unknown})"
}

apply_patches() {
	resolve_kernel_ref
	log "Applying Thunderbolt patch series onto $kernel_ref"
	# A previous `sudo make` / `sudo ./build.sh` in this tree leaves root-owned
	# files and git objects behind; git then fails with confusing "insufficient
	# permission" errors mid-`am` that look like patch conflicts.
	local foreign
	foreign="$(find "$kernel_src" ! -user "$(id -un)" -print -quit 2>/dev/null)"
	if [[ -n "$foreign" ]]; then
		die "$kernel_src contains files not owned by $(id -un) (e.g. $foreign).
       A previous sudo build wrote them. Fix with:
           sudo chown -R $(id -un):$(id -gn) $kernel_src"
	fi

	git -C "$kernel_src" am --abort >/dev/null 2>&1 || true
	git -C "$kernel_src" checkout -q -B tbv-build "$kernel_ref"
	git -C "$kernel_src" clean -qfdx -e .config -e rpmbuild || true

	# 01xx patches are the maintainer-tree series and are already contained in
	# the westeri thunderbolt ref we build from; only the local 00xx
	# series needs applying.
	local p base applied=0 present=0 out
	for p in "$repo_root"/kernel-workflow/patches/00*.patch; do
		base="$(basename "$p")"
		if kernel_should_skip_patch "$base"; then
			printf '    skip    %s\n' "$base"
			continue
		fi
		if out="$(git -C "$kernel_src" am --3way "$p" 2>&1)"; then
			printf '    apply   %s\n' "$base"
			applied=$((applied + 1))
		elif grep -q 'already applied' <<<"$out"; then
			# The ref already carries this commit (e.g. a local branch that was
			# built before). Not an error.
			git -C "$kernel_src" am --skip >/dev/null 2>&1 || true
			printf '    present %s\n' "$base"
			present=$((present + 1))
		else
			git -C "$kernel_src" am --abort >/dev/null 2>&1 || true
			printf '%s\n' "$out" >&2
			die "patch does not apply: $base (add its prefix to PATCH_SKIP if obsolete)"
		fi
	done
	printf '    %d applied, %d already present\n' "$applied" "$present"
}

configure_kernel() {
	log "Seeding config from $kernel_config"
	[[ -r "$kernel_config" ]] || die "no readable kernel config: $kernel_config"
	cp "$kernel_config" "$kernel_src/.config"

	# scripts/setlocalversion appends a "+" for any tree that is not sitting on
	# an annotated tag, unless the LOCALVERSION *environment* variable is set;
	# an empty value counts as set and is what we want, since a non-empty one
	# would be appended on top of CONFIG_LOCALVERSION (yielding -tbv-tbv).
	# .config alone does not suppress the "+", and .scmversion is not consulted
	# on this path, so every `make` below passes LOCALVERSION= explicitly --
	# otherwise the release becomes 7.2.0-rc6-tbv+ and leaks into RPM names.
	local cfg="$kernel_src/scripts/config"
	"$cfg" --file "$kernel_src/.config" \
		--disable LOCALVERSION_AUTO \
		--set-str LOCALVERSION "$localversion" \
		--set-str SYSTEM_TRUSTED_KEYS "" \
		--set-str SYSTEM_REVOCATION_KEYS "" \
		--set-str MODULE_SIG_KEY "certs/signing_key.pem" \
		--disable MODULE_SIG_FORCE \
		--enable THUNDERBOLT \
		--module THUNDERBOLT \
		--enable CONFIGFS_FS

	if [[ "$keep_debug_info" != "1" ]]; then
		# Fedora's config carries full DWARF + BTF; dropping it cuts the build
		# time and the resulting RPM size by a large factor.
		"$cfg" --file "$kernel_src/.config" \
			--disable DEBUG_INFO_BTF \
			--disable DEBUG_INFO_DWARF5 \
			--disable DEBUG_INFO_DWARF4 \
			--disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT \
			--enable DEBUG_INFO_NONE
	fi

	make -C "$kernel_src" LOCALVERSION= olddefconfig >/dev/null
}

build_kernel() {
	apply_patches
	configure_kernel

	local kver
	kver="$(make -s -C "$kernel_src" LOCALVERSION= kernelrelease)"
	log "Building kernel $kver with -j$jobs (this takes a while)"
	make -C "$kernel_src" LOCALVERSION= -j"$jobs" binrpm-pkg

	local kver_pkg="${kver//-/_}"
	printf '%s\n' "$kver" > "$state_file"

	local rpm found=0
	while IFS= read -r rpm; do
		cp "$rpm" "$out_dir/"
		printf '    %s\n' "$out_dir/$(basename "$rpm")"
		found=$((found + 1))
	done < <(find "$kernel_src/rpmbuild/RPMS" -name "*${kver_pkg}*.rpm" -print)
	[[ "$found" -gt 0 ]] || die "binrpm-pkg produced no RPMs matching $kver_pkg"

	log "Kernel RPMs ready ($kver)"
}

# ---------------------------------------------------------------- module ----

resolve_kver() {
	if [[ -n "${KVER:-}" ]]; then
		printf '%s\n' "$KVER"
	elif [[ -r "$state_file" ]]; then
		cat "$state_file"
	else
		die "no kernel built yet; run the kernel stage or set KVER="
	fi
}

resolve_kdir() {
	local kver="$1"
	# Prefer the tree we just built (no need to install kernel-devel first).
	if [[ -n "${KVER:-}" ]] || [[ ! -r "$kernel_src/.config" ]]; then
		:
	elif [[ "$(make -s -C "$kernel_src" LOCALVERSION= kernelrelease 2>/dev/null)" == "$kver" ]]; then
		printf '%s\n' "$kernel_src"
		return 0
	fi
	[[ -d "/usr/src/kernels/$kver" ]] ||
		die "no build tree for $kver; install kernel-devel-$kver from $out_dir"
	printf '%s\n' "/usr/src/kernels/$kver"
}

# Pick the dependency that actually pins the kmod to its kernel. `make
# binrpm-pkg` kernels provide the bare name `kernel-<release>`; distro kernels
# provide `kernel-uname-r = <release>`. A release containing two hyphens (e.g.
# 7.2.0-rc1-tbv+) is not a valid rpm version, so the versioned form cannot be
# used there at all.
kernel_requires() {
	local kver="$1" rpm
	rpm="$(find "$out_dir" -maxdepth 1 -name "kernel-${kver//-/_}*.rpm" -print -quit 2>/dev/null)"
	if [[ -n "$rpm" ]] && rpm -qp --provides "$rpm" 2>/dev/null | grep -qx "kernel-${kver}"; then
		printf 'kernel-%s\n' "$kver"
		return 0
	fi
	if rpm -q --provides "kernel-${kver//-/_}" 2>/dev/null | grep -q "^kernel-uname-r = ${kver}$"; then
		printf 'kernel-uname-r = %s\n' "$kver"
		return 0
	fi
	# No packaged kernel to inspect: fall back on what the release string allows.
	if [[ "$(tr -cd -- '-' <<<"$kver" | wc -c)" -le 1 ]]; then
		printf 'kernel-uname-r = %s\n' "$kver"
	else
		printf 'kernel-%s\n' "$kver"
	fi
}

sign_module() {	local ko="$1" kdir="$2"
	local key="$kdir/certs/signing_key.pem" crt="$kdir/certs/signing_key.x509"
	local signer="$kdir/scripts/sign-file"
	[[ -x "$signer" && -r "$key" && -r "$crt" ]] || return 0
	"$signer" sha256 "$key" "$crt" "$ko"
	printf '    signed with %s\n' "$key"
}

build_module() {
	local kver kdir
	kver="$(resolve_kver)"
	kdir="$(resolve_kdir "$kver")"

	log "Building thunderbolt_ibverbs.ko for $kver (KDIR=$kdir)"
	make -C "$repo_root/kernel" KVER="$kver" KDIR="$kdir" clean >/dev/null 2>&1 || true
	make -C "$repo_root/kernel" KVER="$kver" KDIR="$kdir" -j"$jobs" modules

	local ko="$repo_root/kernel/thunderbolt_ibverbs.ko"
	[[ -r "$ko" ]] || die "module build produced no thunderbolt_ibverbs.ko"

	local rpm_top="$out_dir/.rpmbuild-kmod"
	rm -rf "$rpm_top"
	install -d -m 0755 "$rpm_top"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
	install -m 0644 "$ko" "$rpm_top/SOURCES/thunderbolt_ibverbs.ko"
	sign_module "$rpm_top/SOURCES/thunderbolt_ibverbs.ko" "$kdir"

	local kver_pkg="${kver//-/_}"
	sed -e "s/@VERSION@/${version}/g" -e "s/@KVER@/${kver}/g" \
		-e "s/@KVER_PKG@/${kver_pkg}/g" \
		-e "s|@KERNEL_REQ@|$(kernel_requires "$kver")|g" \
		"$repo_root/packaging/rpm/thunderbolt-ibverbs-kmod.spec" \
		> "$rpm_top/SPECS/thunderbolt-ibverbs-kmod.spec"

	rpmbuild --define "_topdir $rpm_top" -bb \
		"$rpm_top/SPECS/thunderbolt-ibverbs-kmod.spec" > "$out_dir/kmod-rpmbuild.log" 2>&1 ||
		{ cat "$out_dir/kmod-rpmbuild.log" >&2; die "rpmbuild failed for the kmod package"; }

	local rpm
	rpm="$(find "$rpm_top/RPMS" -name '*.rpm' -print -quit)"
	[[ -n "$rpm" ]] || die "rpmbuild produced no kmod RPM"
	cp "$rpm" "$out_dir/"
	rm -rf "$rpm_top"
	log "Built $out_dir/$(basename "$rpm")"
}

# -------------------------------------------------------------- provider ----

detect_rdma_core_tag() {
	[[ -n "${RDMA_CORE_TAG:-}" ]] && { printf '%s\n' "$RDMA_CORE_TAG"; return 0; }
	local v
	v="$(rpm -q --qf '%{VERSION}\n' rdma-core 2>/dev/null | head -n1)"
	if [[ ! "$v" =~ ^[0-9] ]]; then
		v="$(dnf -q repoquery --latest-limit=1 --qf '%{version}' rdma-core.x86_64 2>/dev/null | head -n1)"
	fi
	[[ "$v" =~ ^[0-9] ]] || die "could not determine Fedora's rdma-core version; set RDMA_CORE_TAG"
	printf 'v%s\n' "$v"
}

build_provider() {
	local tag evr
	tag="$(detect_rdma_core_tag)"
	evr="$(rpm -q --qf '%{VERSION}-%{RELEASE}\n' libibverbs 2>/dev/null | head -n1)"
	log "Building usb4_rdma provider against rdma-core $tag (system libibverbs ${evr:-unknown})"

	local abi=""
	[[ -n "$evr" ]] && abi="${evr%%-*}"

	# The provider build itself needs no root, but distro-package-rdma.sh's
	# dep install does; deps are already handled by install_deps above.
	# WORK_DIR is kept so a re-run can reuse the rdma-core checkout.
	RDMA_CORE_TAG="$tag" \
	TBV_VERSION="$version" \
	OUT_DIR="$out_dir" \
	WORK_DIR="${PROVIDER_WORK_DIR:-$out_dir/.rdma-core-build}" \
	TBV_SKIP_DEPS=1 \
	TBV_RDMA_ABI="$abi" \
		bash "$repo_root/tools/ci/distro-package-rdma.sh" fedora
}

# -------------------------------------------------------------- perftest ----

build_perftest() {
	log "Building perftest $perftest_tag for usb4_rdma"

	local rpm_top="$out_dir/.rpmbuild-perftest"
	rm -rf "$rpm_top"
	install -d -m 0755 "$rpm_top"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

	# Cache the tarball so repeat runs (and offline rebuilds) don't refetch.
	local cache="${PERFTEST_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/thunderbolt-ibverbs}"
	local tarball="$cache/perftest-${perftest_tag}.tar.gz"
	install -d -m 0755 "$cache"
	if [[ ! -s "$tarball" ]]; then
		curl -sfL -o "$tarball.part" \
			"https://github.com/linux-rdma/perftest/archive/refs/tags/${perftest_tag}.tar.gz" ||
			{ rm -f "$tarball.part"; die "could not download perftest $perftest_tag"; }
		mv "$tarball.part" "$tarball"
	fi
	# The GitHub tag tarball unpacks to perftest-<tag>/, which is exactly what
	# %autosetup expects, so it can be used as Source0 verbatim.
	cp "$tarball" "$rpm_top/SOURCES/perftest-${perftest_tag}.tar.gz"

	sed -e "s/@PERFTEST_VERSION@/${perftest_tag}/g" \
		"$repo_root/packaging/rpm/usb4-perftest.spec" \
		> "$rpm_top/SPECS/usb4-perftest.spec"

	rpmbuild --define "_topdir $rpm_top" -bb \
		"$rpm_top/SPECS/usb4-perftest.spec" > "$out_dir/perftest-rpmbuild.log" 2>&1 ||
		{ tail -40 "$out_dir/perftest-rpmbuild.log" >&2; die "rpmbuild failed for perftest"; }

	local rpm found=0
	while IFS= read -r rpm; do
		cp "$rpm" "$out_dir/"
		printf '    %s\n' "$out_dir/$(basename "$rpm")"
		found=$((found + 1))
	done < <(find "$rpm_top/RPMS" -name 'usb4-perftest-*.rpm' -print)
	[[ "$found" -gt 0 ]] || die "rpmbuild produced no perftest RPM"
	rm -rf "$rpm_top"
}

# ------------------------------------------------------------------ main ----

install_deps
for stage in "${stages[@]}"; do
	case "$stage" in
		kernel)   build_kernel ;;
		module)   build_module ;;
		provider) build_provider ;;
		perftest) build_perftest ;;
	esac
done

log "Artefacts in $out_dir"
ls -1 "$out_dir"/*.rpm 2>/dev/null || true

cat <<EOF

Install order on the target host:
  sudo dnf install $out_dir/kernel-*.rpm
  sudo dnf install $out_dir/thunderbolt-ibverbs-kmod-*.rpm
  sudo dnf install $out_dir/usb4-rdma-provider-*.rpm $out_dir/usb4-perftest-*.rpm
  sudo reboot   # into the new kernel, then: modprobe thunderbolt_ibverbs

perftest tools install as usb4_ib_send_bw, usb4_ib_write_bw, ... on PATH
(full prefix at /usr/libexec/usb4-perftest, i.e. TBV_PERFTEST=/usr/libexec/usb4-perftest).
EOF
