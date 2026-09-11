# the minimum version of CMake.
cmake_minimum_required(VERSION 3.5.0)
project(nbconnect)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

include_directories(${NATIVERENDER_ROOT_PATH}
                    ${NATIVERENDER_ROOT_PATH}/include)

add_library(netbird SHARED napi_init.cpp)

# Go c-archive：HarmonyOS NetBird Core C ABI，包含真实 client/internal 与 WireGuard 依赖。
set(GO_ARCHIVE ${NATIVERENDER_ROOT_PATH}/libnbharmony.a)

# Go runtime 需要 pthread / dl。libnbharmony.a 中被 napi_init.cpp 直接引用的 Core API
# 会正常拉入，Go runtime 初始化代码经依赖传递一并链入；不使用 whole-archive。
target_link_libraries(netbird PUBLIC
    libace_napi.z.so
    ${GO_ARCHIVE}
    libnet_connection.so
    pthread
    dl
)


# OHOS musl rejects Go runtime's single Initial-Exec TLS relocation when this
# N-API library is loaded with dlopen. Patch the linked ELF before Hvigor's
# ProcessLibs -> DoNativeStrip -> PackageHap -> SignHap pipeline.
find_program(NODE_EXECUTABLE NAMES node.exe node)
if(NOT NODE_EXECUTABLE)
    message(FATAL_ERROR "Node.js is required to patch Go runtime TLS relocation")
endif()

set(TLS_PATCH_SCRIPT "${CMAKE_CURRENT_SOURCE_DIR}/../../../patch_tls.js")
if(NOT EXISTS "${TLS_PATCH_SCRIPT}")
    message(FATAL_ERROR "TLS patch script not found: ${TLS_PATCH_SCRIPT}")
endif()

add_custom_command(TARGET netbird POST_BUILD
    COMMAND "${NODE_EXECUTABLE}" "${TLS_PATCH_SCRIPT}" "$<TARGET_FILE:netbird>"
    COMMENT "Patching Go runtime R_AARCH64_TLS_TPREL64 relocation"
    VERBATIM
)
