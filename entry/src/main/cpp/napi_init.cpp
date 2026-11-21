/**
 * LEGACY — 此文件已不再参与构建。
 *
 * CMakeLists.txt 使用 napi_init_v2.cpp 作为 libhongtu 的 NAPI 入口。
 * 请勿在此文件中添加新 API；所有桥接逻辑改 napi_init_v2.cpp。
 *
 * 保留本文件仅为避免误引用历史路径时静默编译出残缺模块。
 * 若被意外加入 target，编译期直接失败。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

#error "napi_init.cpp is legacy; use napi_init_v2.cpp (see CMakeLists.txt)"
