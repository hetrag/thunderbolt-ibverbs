#!/bin/bash
set -e

REPO_DIR="/home/mig/git/thunderbolt-ibverbs"
PATCHES_DIR="${REPO_DIR}/kernel-workflow/patches"
KERNEL_DIR="${REPO_DIR}/kernel"
USERSPACE_DIR="${REPO_DIR}/userspace/usb4_rdma"

echo "=== 1. Installing Build Dependencies ==="
sudo dnf install -y \
    fedpkg fedora-packager rpmdevtools ncurses-devel pesign grubby rpm-build \
    make gcc flex bison bc elfutils-libelf-devel openssl-devel rsync \
    rdma-core-devel cmake

echo "=== 2. Preparing Kernel Source ==="
KERNEL_SRC_DIR="/home/mig/git/thunderbolt"
echo "Kernel source prepped at: ${KERNEL_SRC_DIR}"

echo "=== 3. Applying Thunderbolt Patches ==="
cd "${KERNEL_SRC_DIR}"
git am --abort 2>/dev/null || true
git reset --hard origin/next
git clean -fd

# Configure git for the root user running via sudo
git config user.name "Build Script"
git config user.email "build@localhost"

# Apply the first patches (00*.patch), excluding 0006
for patch in "${PATCHES_DIR}"/00*.patch; do
    if [[ $(basename "$patch") == 0006-* ]]; then
        echo "Skipping $patch..."
        continue
    fi
    echo "Applying $patch..."
    git am "$patch" || {
        echo "Failed to apply $patch, skipping..."
        git am --abort
    }
done

echo "=== 4. Building and Installing the Custom Kernel ==="
# Copy current config and update it
cp $(ls -1v /boot/config-* | tail -n 1) .config
make olddefconfig

# Append a custom localversion to distinguish this kernel
sed -i 's/CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="-tb-ibverbs"/' .config

# Build kernel and modules
make -j$(nproc)
sudo make modules_install
sudo make install

# Capture the new kernel version
NEW_KVER=$(make kernelrelease)
echo "Installed new kernel: ${NEW_KVER}"

echo "=== 5. Compiling thunderbolt_ibverbs ==="
cd "${KERNEL_DIR}"
make KDIR=/lib/modules/${NEW_KVER}/build clean || true
make KDIR=/lib/modules/${NEW_KVER}/build -j$(nproc)

echo "=== 6. Compiling usb4-rdma-core-provider ==="
cd "${USERSPACE_DIR}"
mkdir -p build
cd build
cmake ..
make -j$(nproc)

echo "=== Build Complete! ==="
echo "You can now reboot into your new kernel (${NEW_KVER}) and load the compiled module."
