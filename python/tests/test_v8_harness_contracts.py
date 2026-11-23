import json
from pathlib import Path
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]


class V8HarnessAndNativeUiContractsTest(unittest.TestCase):
    def test_native_tools_catalog_has_195_tools_and_v8_capabilities(self) -> None:
        tools_json = json.loads((REPO_ROOT / "python/hongtu/native_tools.json").read_text(encoding="utf-8"))
        tools = tools_json["tools"]
        self.assertEqual(len(tools), 195)
        names = {t["name"] for t in tools}
        required_new = {
            "layers.create",
            "layers.delete",
            "layers.delete_empty",
            "layers.clear",
            "layers.rename",
            "layers.reorder",
            "layers.copy_shapes",
            "layers.move_shapes",
            "layers.batch_state",
            "cell.exit_top",
            "cell.exit_parent",
            "cell.set_top",
            "cell.duplicate",
            "cell.clear",
            "instance.place_aref",
            "selection.filter",
            "selection.invert",
            "workspace.close",
            "workspace.rename",
        }
        self.assertTrue(required_new.issubset(names))

    def test_dsh_agent_tools_cover_visual_harness_web_ask_and_embedded_python(self) -> None:
        dsh_agent = (REPO_ROOT / "entry/src/main/ets/services/DshLayoutAgentService.ets").read_text(encoding="utf-8")
        for tool_name in (
            "capture_screenshot",
            "inspect_workbench_ui",
            "automate_workbench_ui",
            "web_search",
            "web_fetch",
            "ask_user",
            "manage_layers",
            "manage_cells",
            "manage_workbench",
            "execute_klayout_python",
        ):
            self.assertIn(f"name: '{tool_name}'", dsh_agent)

    def test_embedded_python_and_gl_lod_sources_present(self) -> None:
        cpp_dir = REPO_ROOT / "entry/src/main/cpp"
        self.assertTrue((cpp_dir / "vendor/pocketpy/pocketpy.c").is_file())
        self.assertTrue((cpp_dir / "vendor/pocketpy/pocketpy.h").is_file())
        self.assertTrue((cpp_dir / "embedded_python_runtime.cpp").is_file())
        self.assertTrue((cpp_dir / "embedded_python_runtime.h").is_file())
        cmake_txt = (cpp_dir / "CMakeLists.txt").read_text(encoding="utf-8")
        self.assertIn("embedded_python_runtime.cpp", cmake_txt)
        self.assertIn("vendor/pocketpy/pocketpy.c", cmake_txt)

    def test_native_ui_components_replace_hand_drawn_icons_and_sheets(self) -> None:
        dsh_design = (REPO_ROOT / "entry/src/main/ets/components/dsh/DshDesign.ets").read_text(encoding="utf-8")
        self.assertIn("SymbolGlyph(resolveDshSymbolResource(this.glyph))", dsh_design)
        self.assertNotIn("Path()\n        .width(this.glyphSize)", dsh_design)

        drawn_status = (REPO_ROOT / "entry/src/main/ets/components/DrawnStatusIcon.ets").read_text(encoding="utf-8")
        self.assertIn("SymbolGlyph(this.symbolForKind())", drawn_status)
        self.assertNotIn("new CanvasRenderingContext2D", drawn_status)

        index_ets = (REPO_ROOT / "entry/src/main/ets/pages/Index.ets").read_text(encoding="utf-8")
        self.assertIn("this.hasActiveUtilitySheet()", index_ets)
        self.assertIn("this.buildActiveUtilitySheet()", index_ets)


if __name__ == "__main__":
    unittest.main()
