import type { PythonInputMode, PythonLayoutArtifact, PythonParameter } from './PythonBridgeService';

export interface PythonTemplate { id: number; name: string; script: string; parameters: string; inputMode: PythonInputMode; sweepName?: string; sweepValues?: string; }
export interface PythonEditorDraft {
  script: string; parameters: string; inputMode: PythonInputMode; request: string;
  sweepName: string; sweepValues: string; templateName: string;
}
export interface PythonWorkspaceBundle { draft?: PythonEditorDraft; templates: PythonTemplate[]; }
export interface PythonBundleRestoreResult { importedTemplates: number; draftRestored: boolean; renamedTemplates: string[]; }
export interface PythonRunRecord {
  id: number; timestamp: number; name: string; script: string; parameters: string;
  inputMode: PythonInputMode; success: boolean; message: string; artifact?: PythonLayoutArtifact;
}
class PythonWorkspaceService {
  private serial: number = 0;
  private validMode(mode: PythonInputMode): boolean { return mode === 'new' || mode === 'document' || mode === 'selection'; }
  private validDraft(draft: PythonEditorDraft): boolean {
    return draft !== null && typeof draft === 'object' && this.validMode(draft.inputMode) &&
      typeof draft.script === 'string' && draft.script.length <= 65536 &&
      typeof draft.parameters === 'string' && draft.parameters.length <= 512 * 1024 &&
      typeof draft.request === 'string' && draft.request.length <= 16000 &&
      typeof draft.sweepName === 'string' && draft.sweepName.length <= 256 &&
      typeof draft.sweepValues === 'string' && draft.sweepValues.length <= 2048 &&
      typeof draft.templateName === 'string' && draft.templateName.length <= 100;
  }
  draft(registerStorage: boolean = true): PythonEditorDraft | undefined {
    if (registerStorage) PersistentStorage.persistProp('hongtu_python_editor_draft', '');
    try {
      const draft = JSON.parse(AppStorage.get<string>('hongtu_python_editor_draft') ?? '') as PythonEditorDraft;
      return this.validDraft(draft) ? draft : undefined;
    } catch (_) { return undefined; }
  }
  saveDraft(draft: PythonEditorDraft): void {
    // Incomplete parameter JSON is useful while editing; execution validates it later.
    if (!this.validDraft(draft)) throw new Error('Python 草稿无效，已有草稿保留');
    this.commitStorage('hongtu_python_editor_draft', JSON.stringify(draft), '');
  }
  /** Restore an already-owned document's draft without merging its templates again. */
  restoreSessionDraft(draft?: PythonEditorDraft): void {
    if (draft !== undefined && !this.validDraft(draft)) throw new Error('工程 Python 草稿无效');
    PersistentStorage.persistProp('hongtu_python_editor_draft', '');
    const prior: string = AppStorage.get<string>('hongtu_python_editor_draft') ?? '';
    try { this.writeBundleStorage('hongtu_python_editor_draft', draft === undefined ? '' : JSON.stringify(draft)); }
    catch (failure) {
      const restored: boolean = this.resetBundleStorage('hongtu_python_editor_draft', prior);
      throw new Error(`工程草稿切换失败：${String(failure)}；${restored ? '原草稿已保留' : '存储回滚未完成'}`);
    }
  }
  private readTemplates(registerStorage: boolean = true): PythonTemplate[] {
    if (registerStorage) PersistentStorage.persistProp('hongtu_python_templates', '[]');
    try {
      const items = JSON.parse(AppStorage.get<string>('hongtu_python_templates') ?? '[]') as PythonTemplate[];
      return Array.isArray(items) ? items.filter(item => typeof item.name === 'string' && typeof item.script === 'string').slice(0, 32) : [];
    } catch (_) { return []; }
  }
  templates(): PythonTemplate[] { return this.readTemplates(); }
  /** Explicit field selection; service credentials and run history are never part of an engineering bundle. */
  exportBundle(): PythonWorkspaceBundle {
    const bundle: PythonWorkspaceBundle = { draft: this.draft(), templates: this.readTemplates() };
    return this.validateBundle(bundle);
  }
  /** Observe tool semantics for confirmation/save guards without creating storage keys. */
  peekBundle(): PythonWorkspaceBundle {
    return this.validateBundle({ draft: this.draft(false), templates: this.readTemplates(false) });
  }
  validateBundle(bundle: PythonWorkspaceBundle): PythonWorkspaceBundle {
    if (bundle === null || typeof bundle !== 'object' || !Array.isArray(bundle.templates) || bundle.templates.length > 32) throw new Error('工程 Python 模板结构或数量无效');
    const selected: PythonWorkspaceBundle = { templates: [] };
    if (bundle.draft !== undefined) {
      if (!this.validDraft(bundle.draft)) throw new Error('工程 Python 草稿无效');
      const draft: PythonEditorDraft = bundle.draft;
      selected.draft = { script: draft.script, parameters: draft.parameters, inputMode: draft.inputMode, request: draft.request,
        sweepName: draft.sweepName, sweepValues: draft.sweepValues, templateName: draft.templateName };
    }
    const ids: Set<number> = new Set<number>();
    for (const item of bundle.templates) {
      if (item === null || typeof item !== 'object' || !Number.isSafeInteger(item.id) || item.id < 0 || ids.has(item.id) ||
        typeof item.name !== 'string' || !item.name.trim() || item.name.length > 100 || typeof item.script !== 'string' ||
        !item.script.trim() || item.script.length > 65536 || typeof item.parameters !== 'string' || item.parameters.length > 512 * 1024 ||
        !this.validMode(item.inputMode) || (item.sweepName !== undefined && (typeof item.sweepName !== 'string' || item.sweepName.length > 256)) ||
        (item.sweepValues !== undefined && (typeof item.sweepValues !== 'string' || item.sweepValues.length > 2048))) throw new Error('工程 Python 模板无效或 ID 重复');
      this.sweep(item.parameters, item.sweepName ?? '', item.sweepValues ?? '');
      selected.templates.push({ id: item.id, name: item.name, script: item.script, parameters: item.parameters, inputMode: item.inputMode,
        sweepName: item.sweepName, sweepValues: item.sweepValues });
      ids.add(item.id);
    }
    return selected;
  }
  private writeBundleStorage(key: string, value: string): void {
    AppStorage.setOrCreate<string>(key, value);
    if (AppStorage.get<string>(key) !== value) throw new Error('脚本存储回读不一致');
  }
  private resetBundleStorage(key: string, value: string): boolean {
    try {
      if (AppStorage.get<string>(key) === value) return true;
      this.writeBundleStorage(key, value); return true;
    }
    catch (_) { return false; }
  }
  /** A convenience save must use the same verified publication as engineering restoration. */
  private commitStorage(key: string, value: string, initial: string): void {
    PersistentStorage.persistProp(key, initial);
    const prior: string = AppStorage.get<string>(key) ?? initial;
    try { this.writeBundleStorage(key, value); }
    catch (failure) {
      const restored: boolean = this.resetBundleStorage(key, prior);
      throw new Error(`Python 内容保存失败：${String(failure)}；${restored ? '原内容已保留' : '存储回滚未完成'}`);
    }
  }
  /** Exact replacement for a caller's transaction rollback; never merges templates. */
  replaceBundle(bundle: PythonWorkspaceBundle): void {
    const incoming: PythonWorkspaceBundle = this.validateBundle(bundle);
    PersistentStorage.persistProp('hongtu_python_templates', '[]');
    PersistentStorage.persistProp('hongtu_python_editor_draft', '');
    const priorTemplates: string = AppStorage.get<string>('hongtu_python_templates') ?? '[]';
    const priorDraft: string = AppStorage.get<string>('hongtu_python_editor_draft') ?? '';
    try {
      this.writeBundleStorage('hongtu_python_templates', JSON.stringify(incoming.templates));
      this.writeBundleStorage('hongtu_python_editor_draft', incoming.draft === undefined ? '' : JSON.stringify(incoming.draft));
    } catch (failure) {
      const templatesRestored: boolean = this.resetBundleStorage('hongtu_python_templates', priorTemplates);
      const draftRestored: boolean = this.resetBundleStorage('hongtu_python_editor_draft', priorDraft);
      throw new Error(`脚本快照恢复失败：${String(failure)}；${templatesRestored && draftRestored ? '原存储已保留' : '存储回滚未完成'}`);
    }
  }

  /** Called only by the explicit restore action. Merge templates and preserve same-name content. */
  restoreBundle(bundle: PythonWorkspaceBundle, restoreDraft: boolean = true): PythonBundleRestoreResult {
    const incoming: PythonWorkspaceBundle = this.validateBundle(bundle);
    const existing: PythonWorkspaceBundle = this.validateBundle({ templates: this.readTemplates() });
    const items: PythonTemplate[] = existing.templates;
    const renamed: string[] = [];
    let imported: number = 0;
    let nextId: number = items.reduce((highest: number, item: PythonTemplate): number => Math.max(highest, item.id), Date.now()) + 1;
    for (const item of incoming.templates) {
      const renamedPrefix: string = `${item.name.slice(0, 84)}（工程 `;
      const identical: boolean = items.some((saved: PythonTemplate): boolean => (saved.name === item.name ||
        (saved.name.startsWith(renamedPrefix) && saved.name.endsWith('）'))) && saved.script === item.script &&
        saved.parameters === item.parameters && saved.inputMode === item.inputMode && (saved.sweepName ?? '') === (item.sweepName ?? '') &&
        (saved.sweepValues ?? '') === (item.sweepValues ?? ''));
      if (identical) continue;
      let name: string = item.name;
      let suffix: number = 1;
      while (items.some((saved: PythonTemplate): boolean => saved.name === name)) name = `${item.name.slice(0, 84)}（工程 ${suffix++}）`;
      if (name !== item.name) renamed.push(name);
      if (items.length >= 32 || !Number.isSafeInteger(nextId)) throw new Error('恢复模板超过 32 项容量或 ID 上限，原模板和草稿均保留');
      items.push({ id: nextId++, name, script: item.script, parameters: item.parameters, inputMode: item.inputMode,
        sweepName: item.sweepName, sweepValues: item.sweepValues });
      imported++;
    }
    PersistentStorage.persistProp('hongtu_python_editor_draft', '');
    const oldTemplates: string = AppStorage.get<string>('hongtu_python_templates') ?? '[]';
    const oldDraft: string = AppStorage.get<string>('hongtu_python_editor_draft') ?? '';
    const draftRestored: boolean = restoreDraft && incoming.draft !== undefined;
    try {
      this.writeBundleStorage('hongtu_python_templates', JSON.stringify(items));
      if (draftRestored) this.writeBundleStorage('hongtu_python_editor_draft', JSON.stringify(incoming.draft));
    } catch (failure) {
      const templatesRestored: boolean = this.resetBundleStorage('hongtu_python_templates', oldTemplates);
      const draftReset: boolean = this.resetBundleStorage('hongtu_python_editor_draft', oldDraft);
      throw new Error(`工程脚本恢复失败：${String(failure)}；${templatesRestored && draftReset ? '原模板和草稿已保留' : '回滚未完成，请保留工程文件并检查存储'}`);
    }
    return { importedTemplates: imported, draftRestored, renamedTemplates: renamed };
  }
  saveTemplate(name: string, script: string, parameters: string, inputMode: PythonInputMode,
    sweepName: string = '', sweepValues: string = ''): void {
    if (!name.trim() || name.length > 100 || !script.trim() || script.length > 65536) throw new Error('模板名称或脚本无效');
    if (parameters.length > 512 * 1024 || sweepName.length > 256 || sweepValues.length > 2048) throw new Error('模板参数或扫参文本超过保存预算');
    if (!this.validMode(inputMode)) throw new Error('模板运行范围无效');
    this.sweep(parameters, sweepName, sweepValues);
    const previous: PythonTemplate[] = this.validateBundle({ templates: this.readTemplates() }).templates;
    const items: PythonTemplate[] = previous.filter(item => item.name !== name.trim());
    if (items.length >= 32) throw new Error('模板已达到 32 项容量，请先删除不需要的模板；已有模板保留');
    const id: number = Math.max(Date.now() + this.serial + 1, previous.reduce((highest: number, item: PythonTemplate): number => Math.max(highest, item.id), 0) + 1);
    if (!Number.isSafeInteger(id)) throw new Error('模板 ID 超出安全整数范围，已有模板保留');
    items.unshift({ id, name: name.trim(), script, parameters, inputMode, sweepName, sweepValues });
    this.commitStorage('hongtu_python_templates', JSON.stringify(items), '[]');
    this.serial++;
  }
  removeTemplate(id: number): void {
    this.commitStorage('hongtu_python_templates', JSON.stringify(this.readTemplates().filter(item => item.id !== id)), '[]');
  }
  history(): PythonRunRecord[] {
    PersistentStorage.persistProp('hongtu_python_history', '[]');
    try {
      const items = JSON.parse(AppStorage.get<string>('hongtu_python_history') ?? '[]') as PythonRunRecord[];
      return Array.isArray(items) ? items.filter(item => typeof item.script === 'string' && typeof item.timestamp === 'number').slice(0, 40) : [];
    } catch (_) { return []; }
  }
  record(name: string, script: string, parameters: string, inputMode: PythonInputMode,
    success: boolean, message: string, artifact?: PythonLayoutArtifact): PythonRunRecord {
    const item: PythonRunRecord = { id: Date.now() + ++this.serial, timestamp: Date.now(), name, script,
      parameters, inputMode, success, message, artifact };
    const items = this.history(); items.unshift(item);
    this.commitStorage('hongtu_python_history', JSON.stringify(items.slice(0, 40)), '[]');
    return item;
  }
  parseParameters(text: string): PythonParameter[] {
    const values = JSON.parse(text.trim() || '{}') as Record<string, number | string | boolean>;
    if (values === null || typeof values !== 'object' || Array.isArray(values)) throw new Error('参数须为 JSON 对象');
    const names = Object.keys(values);
    if (names.length > 64) throw new Error('参数最多 64 项');
    const result: PythonParameter[] = [];
    for (const name of names) {
      const value = values[name];
      if (!/^[A-Za-z][A-Za-z0-9_]{0,63}$/.test(name) || !['number', 'string', 'boolean'].includes(typeof value)) {
        throw new Error('参数名称须为标识符，值须为数值、文本或布尔值');
      }
      if (typeof value === 'number' && (!Number.isFinite(value) || Math.abs(value) > 1e12)) throw new Error('参数数值无效');
      if (typeof value === 'string' && value.length > 4096) throw new Error('参数文本过长');
      result.push({ name, value });
    }
    return result;
  }
  sweep(parameters: string, name: string, valuesText: string): PythonParameter[][] {
    const base = this.parseParameters(parameters);
    if (!name.trim()) return [base];
    if (!/^[A-Za-z][A-Za-z0-9_]{0,63}$/.test(name)) throw new Error('扫参名称无效');
    const tokens: string[] = valuesText.split(',').map(value => value.trim());
    const values = tokens.map(value => Number(value));
    if (values.length === 0 || values.length > 16 || tokens.some(value => value.length === 0) ||
      values.some(value => !Number.isFinite(value) || Math.abs(value) > 1e12)) throw new Error('扫参需填写 1–16 个逗号分隔数值');
    if (base.length >= 64 && !base.some(item => item.name === name)) throw new Error('加入扫参后参数最多 64 项');
    return values.map(value => base.filter(item => item.name !== name).concat([{ name, value }]));
  }
}
export const pythonWorkspaceService = new PythonWorkspaceService();
