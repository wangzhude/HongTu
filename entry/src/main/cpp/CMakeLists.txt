cmake_minimum_required(VERSION 3.16)
project(hongtu_native LANGUAGES C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Optimization and warning flags
set(CMAKE_C_FLAGS_RELEASE "-O3 -DNDEBUG")
set(CMAKE_C_FLAGS_DEBUG "-g -O0")
set(CMAKE_CXX_FLAGS_RELEASE "-O3 -DNDEBUG")
set(CMAKE_CXX_FLAGS_DEBUG "-g -O0")
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

# NAPI 头文件路径
include_directories(${NATIVERENDER_ROOT_PATH}
                    ${NATIVERENDER_ROOT_PATH}/include
                    ${NATIVERENDER_ROOT_PATH}/sysroot/usr/include
                    ${NATIVERENDER_ROOT_PATH}/sysroot/usr/include/c++/v1)

# 鸿图原生库 v0.4 — 完整 EDA 引擎（含 OH_NativeVSync 独立渲染线程、亚像素 LOD 与端侧内置 Python 3 虚拟机）
add_library(hongtu SHARED
    napi_init_v2.cpp
    gdsii_reader.cpp
    gdsii_writer.cpp
    oasis_reader.cpp
    oasis_writer.cpp
    gl_renderer.cpp
    xcomponent_plugin.cpp
    embedded_python_runtime.cpp
    vendor/pocketpy/pocketpy.c
    vendor/clipper2/src/clipper.engine.cpp
    vendor/clipper2/src/clipper.offset.cpp
    vendor/clipper2/src/clipper.rectclip.cpp
)
target_include_directories(hongtu PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/clipper2/include
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/pocketpy
)
target_compile_definitions(hongtu PRIVATE PK_ENABLE_WATCHDOG=1 PK_ENABLE_OS=1)
set_source_files_properties(vendor/pocketpy/pocketpy.c PROPERTIES
    COMPILE_OPTIONS "-Wno-unused-parameter;-Wno-sign-compare"
)

# 链接鸿蒙 NAPI 运行时 + OpenGL ES + EGL + XComponent + NativeVSync + 日志 + zlib(OASIS CBLOCK)
target_link_libraries(hongtu PUBLIC
    libace_napi.z.so
    libace_ndk.z.so
    libEGL.so
    libGLESv3.so
    libhilog_ndk.z.so
    libnative_window.so
    libnative_buffer.so
    libnative_vsync.so
    libz.so
    ${CMAKE_DL_LIBS}
)

# 导出符号可见（鸿蒙 dlsym("main") 启动需要）
set_target_properties(hongtu PROPERTIES
    CXX_VISIBILITY_PRESET default
    VISIBILITY_INLINES_HIDDEN OFF
)

# 编译警告
target_compile_options(hongtu PRIVATE -Wall -Wextra -Wno-unused-parameter)
