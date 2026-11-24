# Native Markdown renderer

The chat UI uses the upstream ArkUI renderer **@luvi/lv-markdown-in 3.4.7**, rather than a HongTu Markdown parser. The exact production package and transitive dependencies are pinned by `entry/oh-package-lock.json5`, including OHPM archive SHA-512 integrity values. Installed `oh_modules` files are not patched.

| Package | Version | License | Public upstream |
|---|---|---|---|
| @luvi/lv-markdown-in | 3.4.7 | MIT, Copyright 2023-present LiuWei | [Source](https://gitee.com/luvi/lv-markdown-in), [OHPM metadata](https://ohpm.openharmony.cn/ohpm/@luvi%2Flv-markdown-in) |
| @luvi/html2md | 1.0.3 | MIT | [Source](https://gitee.com/luvi/html2md) |
| @cangjie-tpc/formula_hybrid | 1.3.0 | MIT | [Source](https://gitcode.com/Cangjie-TPC/formula-ffi/tree/formula-ffi_hybrid_cangjie-plugin_5.1.1) |
| @cangjie-tpc/prism_hybrid | 1.2.6 | Apache-2.0 | [Source](https://gitcode.com/Cangjie-TPC/prism4cj/tree/prism4cj_hybrid_cangjie-plugin_5.1.1) |

Exact upstream license files are retained under `third_party/markdown/`, with their hashes and public archive URLs in `provenance.json`. Formula and Prism upstream `README.OpenSource` records are also retained; they credit MicroTeX, MathJax-mhchem and Prism4j. This supplements the separate [Python dependency notices](python/THIRD_PARTY_NOTICES.md) and existing C++ vendor licenses.

**Source publication boundary:** the installed OHPM binary HAR is version 3.4.7; the publicly available source review snapshot declares 3.4.6. Its commit is [2adcf6990b97bc4f83d22eff4333e65dd8dc5fb1](https://gitee.com/luvi/lv-markdown-in/tree/2adcf6990b97bc4f83d22eff4333e65dd8dc5fb1). No matching public 3.4.7 source tag was exposed during the 2026-09-30 review. The metadata/declaration APIs and package integrity were checked separately; we do not claim this public source commit reproduces the shipped bytecode HAR.

To reinstall, run DevEco's `ohpm install --all` from the repository root while retaining the checked-in lockfile. To independently re-download and verify the public archives and license files, run:

```powershell
python tools/verify_markdown_upstream.py --download-dir artifacts/markdown-upstream
node tools/markdown_dependency_host_check.mjs
```

The verification script never installs or patches dependencies. Both native transitive packages include x86_64 and arm64-v8a ELF libraries and declare minimum API 12. Package metadata and ELF checks alone do not establish API 24 build or device rendering success.

Integration uses text mode with reactive updates and the existing outer chat scroll. HTML preview, Mermaid preview, Web preview pooling and image loading are disabled. A deliberate click on a valid HTTP(S) link opens it through the native system URL handler; other schemes are rejected. A wrapper neutralizes the upstream `$rawfile(` image shortcut before rendering because that shortcut bypasses the upstream image proxy. Original chat text and tool arguments remain unchanged. Library code/table blocks supply horizontal scrolling; no custom Markdown parser or renderer is introduced.

# Embedded CPython

HongTu packages CPython 3.12.3 for HarmonyOS as `libpython3.12.so` for arm64-v8a and x86_64, with a bytecode standard-library archive and headers for native integration. The platform builds statically include selected CPython extension modules.

The [CPython 3.12.3 source](https://github.com/python/cpython/tree/v3.12.3) is distributed under the upstream [license and notices](entry/src/main/resources/rawfile/cpython312-LICENSE.txt), which are also packaged with the app.
