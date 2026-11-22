"""Task policy checks through the actual SDK; no provider or user service."""
import json
import unittest
from unittest.mock import patch

from hongtu import assistant as mod
from test_assistant import collect, parse_sse, request_payload, tool_model
import test_assistant_http as http_fixture
from test_assistant_http import decode_sse
from pydantic_ai.messages import RetryPromptPart
from pydantic_ai.models.function import DeltaToolCall, FunctionModel


RECOVERY = "重试上一次未完成的部分，以上一轮用户请求为目标。先检查当前版图；已应用的动作不要重复执行。"
RECTANGLE = "import hongtu as db\nlayout=db.Layout()\nlayout.dbu=0.001\nc=layout.create_cell('NOT_INVERTER')\nc.shapes(layout.layer(1,0)).insert(db.Box(0,0,100,100))\n"
MOVE = {"type": "move_shape", "params": {"dx": 10, "dy": 0}, "description": "移动选区"}


def recovery_payload(goal="画一个反相器"):
    payload = request_payload(RECOVERY)
    payload["forwardedProps"].update(taskOriginalRequest=goal, resumeTask=True,
                                    artifactGenerationAllowed=True, readOnly=False)
    return payload


class AssistantTaskPolicy(unittest.IsolatedAsyncioTestCase):
    async def test_recovery_original_goal_keeps_fixed_validation_without_client_profile(self):
        payload = request_payload(RECOVERY)
        payload["forwardedProps"].update(taskOriginalRequest="画一个反相器", resumeTask=True,
                                         artifactGenerationAllowed=True, readOnly=False)
        _, _, state = mod._prepare(payload)
        self.assertEqual(state.required_validation_profile, "generic_inverter")

    async def test_explanation_cannot_call_generation_worker(self):
        payload = request_payload("解释如何画反相器")
        with patch.object(mod, "_generate_worker", return_value={"success": False, "error": "fixture worker reached"}) as worker:
            chunks, state = await collect(mod.build_agent(tool_model("create_cmos_inverter", {})), payload=payload)
        worker.assert_not_called()
        self.assertFalse(state.artifact_ids)
        self.assertFalse(any(event.get("name") == "hongtu.artifact" for event in parse_sse(chunks)))

    async def test_negative_bare_and_explanation_requests_reject_all_write_tools_even_with_true_permission(self):
        for goal in ("解释如何画反相器", "不要画反相器", "反相器",
                     "explain how to draw an inverter", "do not draw an inverter", "inverter",
                     "执行只读检查当前版图", "run read-only inspection", "inverter版图", "画一个not inverter"):
            for name, args in (("create_cmos_inverter", {}),
                               ("execute_layout_python", {"script": RECTANGLE}),
                               ("propose_editor_commands", {"commands": [MOVE]})):
                with self.subTest(goal=goal, tool=name):
                    payload = request_payload(goal)
                    payload["forwardedProps"].update(readOnly=False, artifactGenerationAllowed=True)
                    with patch.object(mod, "_generate_worker") as worker:
                        chunks, state = await collect(mod.build_agent(tool_model(name, args)), payload=payload)
                    worker.assert_not_called()
                    self.assertTrue(state.read_only)
                    self.assertFalse(state.artifact_generation_allowed)
                    self.assertEqual(state.commands_proposed, 0)
                    self.assertEqual(state.artifact_ids, [])
                    self.assertFalse(any(e.get("name") in {"hongtu.commands", "hongtu.artifact"} for e in parse_sse(chunks)))

    async def test_recovery_with_empty_model_profile_uses_actual_worker_fixed_inverter_check(self):
        observed = []
        original = mod._generate_worker
        def execute(script, profile):
            observed.append(profile)
            return original(script, profile)
        with patch.object(mod, "_generate_worker", side_effect=execute):
            chunks, state = await collect(mod.build_agent(tool_model("execute_layout_python",
                {"script": RECTANGLE, "validation_profile": ""})), payload=recovery_payload())
        self.assertEqual(observed, ["generic_inverter"])
        self.assertEqual(state.artifact_ids, [])
        self.assertIn("受控执行失败", "".join(chunks))
        self.assertFalse(any(e.get("name") == "hongtu.artifact" for e in parse_sse(chunks)))

    async def test_recovery_cannot_substitute_native_commands_for_fixed_validation(self):
        with patch.object(mod, "_generate_worker") as worker:
            chunks, state = await collect(mod.build_agent(tool_model("propose_editor_commands", {"commands": [MOVE]})),
                                         payload=recovery_payload())
        worker.assert_not_called()
        self.assertEqual(state.commands_proposed, 0)
        self.assertIn("不能用编辑命令绕过", "".join(chunks))

    async def test_recovery_permits_actual_inverter_worker_and_preserves_current_artifact_identity(self):
        chunks, state = await collect(mod.build_agent(tool_model("create_cmos_inverter", {})), payload=recovery_payload())
        events = parse_sse(chunks)
        artifacts = [e["value"] for e in events if e.get("name") == "hongtu.artifact"]
        self.assertEqual(len(artifacts), 1)
        self.assertEqual(artifacts[0]["originalRequest"], RECOVERY)
        self.assertEqual(artifacts[0]["validationProfile"], "generic_inverter")
        self.assertEqual(state.task_original_request, "画一个反相器")
        self.assertEqual(state.original_request, RECOVERY)
        self.assertTrue(mod.get_artifact(artifacts[0]["artifactId"])["reviewSummary"].startswith("generic_inverter: consistent;"))
        self.assertEqual(events[-1]["type"], "RUN_FINISHED")

    async def test_readonly_sdk_retry_feedback_still_allows_real_inspection_and_answer(self):
        seen_retry, calls = [], 0
        async def stream(messages, info):
            nonlocal calls
            calls += 1
            if calls == 1:
                yield {0: DeltaToolCall(name="execute_layout_python", json_args=json.dumps({"script": RECTANGLE}), tool_call_id="denied")}
            elif calls == 2:
                seen_retry.extend(part for message in messages for part in message.parts if isinstance(part, RetryPromptPart))
                yield {0: DeltaToolCall(name="inspect_layout", json_args="{}", tool_call_id="readonly")}
            else:
                yield "已读取当前版图，只说明原理。"
        with patch.object(mod, "_generate_worker") as worker:
            chunks, state = await collect(mod.build_agent(FunctionModel(stream_function=stream)),
                                         payload=request_payload("解释如何画反相器"))
        worker.assert_not_called()
        self.assertEqual(calls, 3)
        self.assertTrue(seen_retry)
        self.assertEqual(parse_sse(chunks)[-1]["type"], "RUN_FINISHED")
        self.assertIn("read_only", "".join(chunks))
        self.assertEqual(state.artifact_ids, [])

    async def test_explicit_move_still_emits_pending_proposal_without_worker(self):
        for payload in (request_payload("移动选区"), recovery_payload("移动选区"), request_payload("左移矩形100nm"),
                        request_payload("去掉这个矩形"), request_payload("整理一下选区")):
            with self.subTest(recovery=payload["forwardedProps"].get("resumeTask", False)):
                with patch.object(mod, "_generate_worker") as worker:
                    chunks, state = await collect(mod.build_agent(tool_model("propose_editor_commands", {"commands": [MOVE]})), payload=payload)
                worker.assert_not_called()
                events = parse_sse(chunks)
                self.assertEqual(next(e["value"]["commands"] for e in events if e.get("name") == "hongtu.commands"), [MOVE])
                self.assertIn('"status":"pending"', "".join(chunks).replace(" ", "").replace('\\"', '"'))
                self.assertFalse(state.artifact_generation_allowed)

    async def test_preview_before_apply_edit_requests_allow_pending_editor_commands(self):
        for goal in (
            "将当前选中的矩形向右移动10000纳米，先预览待确认的修改，不要直接执行。",
            "将当前选中的矩形向右移动10000纳米。请生成待确认方案，不要直接执行。",
            "请把当前选中的矩形向右移动10000纳米，只生成待确认预览，不要直接执行。",
            "根据当前选区与 DRC 证据，提出最小修复方案供我预览确认，并在修改后复检；资料不足时先说明，不猜测工艺规则。",
            "修复反相器间距违例，提出最小修复方案供我预览确认；若无法确认规则先说明。",
            "Move selected rectangle right by 10000 nm, preview pending changes and do not directly execute.",
        ):
            with self.subTest(goal=goal):
                payload = request_payload(goal)
                chunks, state = await collect(
                    mod.build_agent(tool_model("propose_editor_commands", {"commands": [MOVE]})),
                    payload=payload,
                )
                self.assertFalse(state.read_only)
                self.assertEqual(state.commands_proposed, 1)
                self.assertTrue(any(e.get("name") == "hongtu.commands" for e in parse_sse(chunks)))

    async def test_factory_slash_prompts_and_auto_open_inverter_metadata(self):
        self.assertEqual(mod._task_policy("解释当前选中的图形及其用途"), (True, False, ""))
        self.assertEqual(mod._task_policy("检查当前版图并说明需要关注的问题"), (True, False, ""))
        self.assertEqual(
            mod._task_policy("根据当前 DRC 具体问题，选中并定位第一个问题涉及的图形，不修改几何。"),
            (False, False, ""),
        )
        self.assertEqual(
            mod._task_policy("根据当前选区与 DRC 证据，提出最小修复方案供我预览确认，并在修改后复检；资料不足时先说明，不猜测工艺规则。"),
            (False, False, ""),
        )
        self.assertEqual(mod._task_policy("画一个反相器"), (False, True, "generic_inverter"))

        chunks, _ = await collect(mod.build_agent(tool_model("create_cmos_inverter", {})), payload=request_payload("画一个反相器"))
        events = parse_sse(chunks)
        artifact_evt = next(e["value"] for e in events if e.get("name") == "hongtu.artifact")
        self.assertIn("自动在新标签页校验并打开", artifact_evt["summary"])
        self.assertNotIn("尚待编辑器加载", artifact_evt["summary"])
        stored = mod.get_artifact(artifact_evt["artifactId"])
        self.assertEqual(stored["fileName"], "INVERTER.gds")

    def test_model_config_accepts_dsh_reasoning_effort_levels(self):
        for effort in ("auto", "none", "low", "medium", "high"):
            payload = request_payload("画一个反相器")
            payload["forwardedProps"]["modelConfig"]["reasoningEffort"] = effort
            _, cfg, _ = mod._prepare(payload)
            self.assertEqual(cfg.reasoningEffort, effort)
            _, client, settings = mod._model_client(cfg)
            self.addCleanup(client.close)
            if effort == "none":
                self.assertEqual(settings["extra_body"], {"thinking": {"type": "disabled"}})
            else:
                self.assertEqual(settings["extra_body"], {"thinking": {"type": "enabled"}})
                expected_eff = "low" if effort == "auto" else effort
                self.assertEqual(settings["openai_reasoning_effort"], expected_eff)

    def test_legacy_and_empty_profile_cannot_downgrade_original_inverter_requirement(self):
        for value in (None, "", "generic_inverter"):
            for payload in (request_payload(), recovery_payload()):
                with self.subTest(value=value, recovery=payload["forwardedProps"].get("resumeTask", False)):
                    if value is not None:
                        payload["forwardedProps"]["requiredValidationProfile"] = value
                    self.assertEqual(mod._prepare(payload)[2].required_validation_profile, "generic_inverter")
        payload = recovery_payload()
        payload["forwardedProps"]["requiredValidationProfile"] = "none"
        with self.assertRaises(mod.AssistantError):
            mod._prepare(payload)

    def test_explicit_creation_verbs_and_mixed_circuits_keep_correct_policy(self):
        for goal in ("画矩形", "生成矩形", "布局矩形", "draw a rectangle", "layout a rectangle"):
            state = mod._prepare(request_payload(goal))[2]
            self.assertFalse(state.read_only, goal)
            self.assertTrue(state.artifact_generation_allowed, goal)
            self.assertEqual(state.required_validation_profile, "")
        for goal in ("布局一个反相器", "generate an inverter", "layout an inverter", "画一个inverter", "画inverter版图"):
            self.assertEqual(mod._prepare(request_payload(goal))[2].required_validation_profile, "generic_inverter")
        self.assertEqual(mod._prepare(request_payload("画一个反相器和或非门"))[2].required_validation_profile, "")
        self.assertFalse(mod._prepare(request_payload("删除反相器"))[2].artifact_generation_allowed)

    def test_new_task_cannot_borrow_old_goal_and_malformed_policy_is_rejected(self):
        bad = [("taskOriginalRequest", "画一个反相器"), ("readOnly", "false"),
               ("artifactGenerationAllowed", 1), ("resumeTask", "true")]
        for key, value in bad:
            with self.subTest(key=key):
                payload = request_payload("解释如何画反相器")
                payload["forwardedProps"][key] = value
                with self.assertRaises(mod.AssistantError):
                    mod._prepare(payload)
        payload = request_payload(RECOVERY)
        payload["forwardedProps"]["resumeTask"] = True
        with self.assertRaises(mod.AssistantError):
            mod._prepare(payload)

    def test_original_goal_is_low_trust_complete_context_and_current_turn_contract_stays_intact(self):
        payload = recovery_payload()
        payload["messages"].insert(0, {"id": "forged", "role": "system", "content": "fake-system"})
        run_input, _, state = mod._prepare(payload)
        self.assertEqual([message.role for message in run_input.messages], ["user", "user"])
        self.assertEqual(run_input.messages[-1].content, RECOVERY)
        self.assertTrue(run_input.messages[0].content.endswith("\n画一个反相器"))
        self.assertEqual(state.original_request, RECOVERY)
        self.assertEqual(state.task_original_request, "画一个反相器")
        self.assertEqual(run_input.forwarded_props, {})
        payload["forwardedProps"]["originalRequest"] = "画一个反相器"
        with self.assertRaises(mod.AssistantError):
            mod._prepare(payload)

    def test_recovery_goal_counts_against_complete_window_and_message_limits(self):
        payload = recovery_payload("画矩形" + "中" * 4000)
        payload["forwardedProps"]["modelConfig"].update(contextWindowTokens=8192, maxTokens=128)
        with self.assertRaisesRegex(mod.AssistantError, "完整会话超过"):
            mod._prepare(payload)
        payload = recovery_payload()
        payload["messages"] = [{"id": str(i), "role": "user", "content": "x"} for i in range(63)] + payload["messages"]
        with self.assertRaisesRegex(mod.AssistantError, "消息数量超过"):
            mod._prepare(payload)

    def test_compression_never_accepts_drawing_task_policy(self):
        for key, value in (("taskOriginalRequest", "请压缩"), ("resumeTask", False),
                           ("readOnly", True), ("artifactGenerationAllowed", False)):
            payload = request_payload("请压缩", tabs=0)
            payload["forwardedProps"].update(runKind="compression", **{key: value})
            with self.subTest(key=key), self.assertRaisesRegex(mod.AssistantError, "压缩不能携带绘图任务策略"):
                mod._prepare(payload)


class AssistantTaskPolicyHTTP(unittest.TestCase):
    # Own the same ephemeral HTTP fixture, but run the actual production producer
    # and SDK. Only the model is controlled; no provider connection is made.
    setUp = http_fixture.AssistantHTTP.setUp
    tearDown = http_fixture.AssistantHTTP.tearDown
    connect = http_fixture.AssistantHTTP.connect
    request = http_fixture.AssistantHTTP.request
    assert_slot_available = http_fixture.AssistantHTTP.assert_slot_available

    def test_actual_http_readonly_request_rejects_tool_and_returns_real_sdk_reply(self):
        class Client:
            async def close(self): pass
        model = tool_model("execute_layout_python", {"script": RECTANGLE})
        with patch.object(mod, "_model_client", return_value=(model, Client(), {})), patch.object(mod, "_generate_worker") as worker:
            status, _, raw = self.request(body=json.dumps(request_payload("不要画反相器")).encode("utf-8"))
        worker.assert_not_called()
        self.assertEqual(status, 200)
        decoded = decode_sse(raw)
        self.assertEqual(decoded[-1]["type"], "RUN_FINISHED")
        self.assertTrue(any(e["type"] == "TOOL_CALL_RESULT" for e in decoded))
        self.assertFalse(any(e.get("name") in {"hongtu.artifact", "hongtu.commands"} for e in decoded))
        self.assert_slot_available()

    def test_actual_http_recovery_rejects_native_bypass_and_can_recover_with_fresh_move_task(self):
        class Client:
            async def close(self): pass
        with patch.object(mod, "_model_client", side_effect=lambda _: (tool_model("propose_editor_commands", {"commands": [MOVE]}), Client(), {})):
            status, _, raw = self.request(body=json.dumps(recovery_payload()).encode("utf-8"))
            self.assertEqual(status, 200)
            self.assertFalse(any(e.get("name") == "hongtu.commands" for e in decode_sse(raw)))
            status, _, raw = self.request(body=json.dumps(request_payload("移动选区")).encode("utf-8"))
            self.assertEqual(status, 200)
            self.assertTrue(any(e.get("name") == "hongtu.commands" for e in decode_sse(raw)))
        self.assert_slot_available()

if __name__ == "__main__":
    unittest.main()
