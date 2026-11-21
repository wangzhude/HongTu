cmake_minimum_required(VERSION 3.16)
project(hongtu_native)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Optimization and warning flags
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

# 鸿图原生库 v0.3 — 完整 EDA 引擎
# 包含: GDSII/OASIS 解析器 + 空间索引 + 几何引擎 + 布尔运算 + OpenGL ES 渲染器 + NAPI 接口
add_library(hongtu SHARED
    napi_init_v2.cpp
    gdsii_reader.cpp
    gdsii_writer.cpp
    oasis_reader.cpp
    oasis_writer.cpp
    gl_renderer.cpp
    xcomponent_plugin.cpp
    vendor/clipper2/src/clipper.engine.cpp
    vendor/clipper2/src/clipper.offset.cpp
    vendor/clipper2/src/clipper.rectclip.cpp
)
target_include_directories(hongtu PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/vendor/clipper2/include)

# 链接鸿蒙 NAPI 运行时 + OpenGL ES + EGL + XComponent + 日志 + zlib(OASIS CBLOCK)
target_link_libraries(hongtu PUBLIC
    libace_napi.z.so
    libace_ndk.z.so
    libEGL.so
    libGLESv3.so
    libhilog_ndk.z.so
    libnative_window.so
    libnative_buffer.so
    libz.so
)

# 导出符号可见（鸿蒙 dlsym("main") 启动需要）
set_target_properties(hongtu PROPERTIES
    CXX_VISIBILITY_PRESET default
    VISIBILITY_INLINES_HIDDEN OFF
)

# 编译警告
target_compile_options(hongtu PRIVATE -Wall -Wextra -Wno-unused-parameter)
