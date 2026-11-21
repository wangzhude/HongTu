"""Protocol outcome checks through the real SDK; model outputs are fixtures."""
import json
from pathlib import Path
import unittest
from hongtu import assistant as mod
from hongtu.native_tools import CATALOG, TOOLS, validate_call, validate_batch
from test_assistant import request_payload, tool_model
from test_assistant_workbench import SDKWorkbenchTests as _SDKFixture


class NativeContractTests(unittest.TestCase):
    def test_generated_native_catalog_matches_backend_byte_for_byte(self):
        path=Path(__file__).resolve().parents[2]/'entry/src/main/ets/services/AiNativeCatalog.ets'
        if not path.exists(): path=Path(__file__).resolve().parents[3]/'entry/src/main/ets/services/AiNativeCatalog.ets'
        text=path.read_text(encoding='utf-8').split(' = ',1)[1].strip().removesuffix(';')
        self.assertEqual(json.loads(json.loads(text)),CATALOG)

    def test_all_native_palette_commands_are_available_as_explicit_handoffs(self):
        root=Path(__file__).resolve().parents[2]
        path=root/'entry/src/main/ets/pages/Index.ets'
        if not path.exists(): path=root.parent/'entry/src/main/ets/pages/Index.ets'
        import re
        source=path.read_text(encoding='utf-8')
        palette=source[source.index('  private workbenchCommands()'):source.index('  private executeWorkbenchCommand(')]
        ids=re.findall(r"add\('([^']+)',",palette)
        self.assertTrue(ids)
        self.assertTrue(set(ids)<=set(TOOLS['workbench.invoke']['parameters']['properties']['commandId']['enum']))

    def test_strict_arguments_reject_unknown_fields_types_nan_and_unregistered_calls(self):
        for name,args in [('cell.create',{'name':'T','shell':'whoami'}),('cell.create',{'name':3}),('ports.remove',{'portId':None}),
                          ('selection.offset',{'shapeIds':[1],'offsetNm':float('nan')}),('shell.execute',{}),('file.open',{'path':'C:/private'})]:
            with self.subTest(name=name,args=args),self.assertRaises(ValueError): validate_call(name,args)

    def test_real_semantic_port_schema_preserves_numeric_version_and_complete_frames(self):
        draft=dict(name='P',centerNm={'x':0,'y':0},orientationDeg=0,widthNm=10,layerNumber=1,datatype=7,portType='electrical',
                   frameMirror=False,frameMagnification=1,infoJson='{}',crossSectionKey='X',crossSectionVersion=1)
        validate_call('ports.add',{'ownerCellId':0,'draft':draft})
        with self.assertRaises(ValueError): validate_call('ports.add',{'ownerCellId':0,'draft':{**draft,'crossSectionVersion':'1'}})

    def test_epoch_based_macro_and_template_ids_are_not_truncated_to_int32(self):
        for name in ['macro.run','macro.remove','python.template_remove']: validate_call(name,{'id':1791500000000})

    def test_geometry_groups_reject_nontransactional_actions_and_reads(self):
        a=mod.NativeToolCall(name='cell.create',arguments={'name':'A'})
        b=mod.NativeToolCall(name='cell.rename',arguments={'cellId':1,'name':'B'})
        validate_batch([a,b])
        for name in ['file.save','workspace.switch','pcells.list']:
            args={'id':'doc'} if name=='workspace.switch' else {}
            with self.subTest(name=name),self.assertRaises(ValueError): validate_batch([a,mod.NativeToolCall(name=name,arguments=args)])


class NativeSDKTests(unittest.IsolatedAsyncioTestCase):
    stream=_SDKFixture.stream

    def payload(self,prompt='执行端口与版图修改'):
        payload=request_payload(prompt)
        payload['forwardedProps']['editorProtocol']='hongtu-editor-query/v1'
        return payload

    async def test_discovery_returns_the_native_schema_to_the_model(self):
        events=await self.stream(tool_model('list_native_tools',{'tool_name':'ports.add'}),self.payload(),
            {'success':True,'version':'native-tools-v1','tool':TOOLS['ports.add']})
        reply=json.loads(next(event['content'] for event in events if event['type']=='TOOL_CALL_RESULT'))
        self.assertEqual(reply['tool']['parameters']['properties']['draft']['properties']['crossSectionVersion']['type'],'integer')

    async def test_read_tool_preserves_structural_port_paths(self):
        path=[{'instanceId':3,'row':0,'col':1,'transform':{'a':1,'b':0,'c':0,'d':1,'tx':40,'ty':10}}]
        events=await self.stream(tool_model('read_native_tool',{'call':{'name':'ports.project','arguments':{}}}),self.payload(),
            {'success':True,'data':[{'endpoint':{'path':path}}]})
        reply=json.loads(next(event['content'] for event in events if event['type']=='TOOL_CALL_RESULT'))
        self.assertEqual(reply['data'][0]['endpoint']['path'],path)

    async def test_parameterized_native_operations_become_pending_not_executed(self):
        events=await self.stream(tool_model('propose_native_tools',{'operations':[{'name':'cell.create','arguments':{'name':'C'}}]}),self.payload(),
            {'success':True,'version':'native-tools-v1'})
        commands=next(e['value']['commands'] for e in events if e.get('name')=='hongtu.commands')
        self.assertEqual(commands[0]['type'],'native_tool')
        self.assertEqual(json.loads(commands[0]['params']['argumentsJson']),{'name':'C'})
        result=json.loads(next(e['content'] for e in events if e['type']=='TOOL_CALL_RESULT'))
        self.assertEqual(result['status'],'pending')
        self.assertFalse(any(e.get('name')=='hongtu.artifact' for e in events))

    async def test_readonly_and_fixed_circuit_policies_cannot_be_bypassed(self):
        for prompt in ['解释端口如何连接','画一个反相器']:
            events=await self.stream(tool_model('propose_native_tools',{'operations':[{'name':'cell.create','arguments':{'name':'C'}}]}),self.payload(prompt))
            self.assertFalse(any(e.get('name') in {'hongtu.commands','hongtu.editor_query'} for e in events))

    async def test_privacy_optout_blocks_document_reads_and_proposals(self):
        payload=self.payload();payload['forwardedProps']['layoutContext']['layoutContextIncluded']=False
        for name,args in [('read_native_tool',{'call':{'name':'ports.project','arguments':{}}}),
                          ('propose_native_tools',{'operations':[{'name':'cell.create','arguments':{'name':'C'}}]})]:
            payload=self.payload();payload['forwardedProps']['layoutContext']['layoutContextIncluded']=False
            events=await self.stream(tool_model(name,args),payload)
            self.assertFalse(any(e.get('name')=='hongtu.editor_query' for e in events))

    async def test_old_client_and_mutation_via_read_tool_do_not_emit_commands(self):
        events=await self.stream(tool_model('propose_native_tools',{'operations':[{'name':'cell.create','arguments':{'name':'C'}}]}),self.payload(),{'success':False})
        self.assertFalse(any(e.get('name')=='hongtu.commands' for e in events))
        events=await self.stream(tool_model('read_native_tool',{'call':{'name':'cell.create','arguments':{'name':'C'}}}),self.payload())
        self.assertFalse(any(e.get('name')=='hongtu.editor_query' for e in events))


# Imported fixture is used only as a helper, not re-discovered as this suite.
del _SDKFixture

if __name__=='__main__': unittest.main()
