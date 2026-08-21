cmake_minimum_required(VERSION 3.10)
project(usb4_rdma C)

find_package(PkgConfig REQUIRED)
pkg_check_modules(LIBIBVERBS REQUIRED libibverbs)

add_library(usb4_rdma-rdmav34 SHARED usb4_rdma.c)
target_include_directories(usb4_rdma-rdmav34 PRIVATE ${LIBIBVERBS_INCLUDE_DIRS})
target_link_libraries(usb4_rdma-rdmav34 ${LIBIBVERBS_LIBRARIES})

# Make the output file exactly usb4_rdma-rdmav34.so (no "lib" prefix)
set_target_properties(usb4_rdma-rdmav34 PROPERTIES PREFIX "")
