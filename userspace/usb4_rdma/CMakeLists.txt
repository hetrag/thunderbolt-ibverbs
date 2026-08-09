cmake_minimum_required(VERSION 3.10)
project(usb4_rdma C)

find_package(PkgConfig REQUIRED)
pkg_check_modules(LIBIBVERBS REQUIRED libibverbs)

# Extract rdma-core version from libibverbs package version
# (rdma-core versions are typically integers like "50.0" or "55.0")
if(LIBIBVERBS_VERSION VERSION_LESS "55")
    add_definitions(-DUSB4_RDMA_OLD_GET_CONTEXT=1)
    add_definitions(-DUSB4_RDMA_OLD_REG_DMABUF_MR=1)
endif()

add_library(usb4_rdma-rdmav34 SHARED usb4_rdma.c)
target_include_directories(usb4_rdma-rdmav34 PRIVATE ${LIBIBVERBS_INCLUDE_DIRS})
target_link_libraries(usb4_rdma-rdmav34 ${LIBIBVERBS_LIBRARIES})

# Make the output file exactly usb4_rdma-rdmav34.so (no "lib" prefix)
set_target_properties(usb4_rdma-rdmav34 PROPERTIES PREFIX "")
