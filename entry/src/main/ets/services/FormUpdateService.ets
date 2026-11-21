/** Persistent complete snapshots shared by the application and form ability. */
import { Context } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { formBindingData, formProvider } from '@kit.FormKit';
import { cloneStructured } from '../common/CloneUtils';
import { layoutConcurrencyService } from './LayoutConcurrencyService';

export interface FormDrcSummary {
  errors: number; warnings: number; passed: boolean;
  executedRules: number; totalRules: number; completenessNotices: number;
}
export interface FormSnapshot {
  version: number; fileName: string; fileType: string; fileSize: number;
  documentId: string; contextIdentity: string;
  drcErrors: number; drcWarnings: number; drcPassed: boolean;
  drcChecked: boolean; drcIncomplete: boolean; drcScope: string; updateTime: string;
}
export function buildFormSnapshot(documentId: string, contextIdentity: string, fileName: string,
  fileType: string, fileSize: number, drc?: FormDrcSummary, scope: string = ''): FormSnapshot {
  const checked: boolean = drc !== undefined;
  const incomplete: boolean = drc !== undefined && (drc.executedRules <= 0 ||
    drc.executedRules < drc.totalRules || drc.completenessNotices > 0);
  return { version: 1, documentId, contextIdentity, fileName: fileName || '尚未打开文件', fileType,
    fileSize: Number.isFinite(fileSize) && fileSize >= 0 ? fileSize : 0,
    drcErrors: drc?.errors ?? 0, drcWarnings: drc?.warnings ?? 0,
    drcPassed: checked && !incomplete && drc?.passed === true && drc.errors === 0,
    drcChecked: checked, drcIncomplete: incomplete, drcScope: checked ? scope : '', updateTime: '' };
}
export function defaultFormSnapshot(): FormSnapshot {
  return buildFormSnapshot('', '', '尚未打开文件', '版图', 0);
}
/** Damaged or legacy records cannot prove a complete check. */
export function parseFormSnapshot(text: string): FormSnapshot {
  try {
    const data = JSON.parse(text) as FormSnapshot;
    if (data.version !== 1 || typeof data.fileName !== 'string' || typeof data.fileType !== 'string' ||
      typeof data.documentId !== 'string' || typeof data.contextIdentity !== 'string' ||
      !Number.isFinite(data.fileSize) || data.fileSize < 0 ||
      !Number.isInteger(data.drcErrors) || data.drcErrors < 0 ||
      !Number.isInteger(data.drcWarnings) || data.drcWarnings < 0 ||
      typeof data.drcChecked !== 'boolean' || typeof data.drcIncomplete !== 'boolean' ||
      typeof data.drcPassed !== 'boolean' || typeof data.drcScope !== 'string' || typeof data.updateTime !== 'string') {
      return defaultFormSnapshot();
    }
    if (!data.drcChecked) {
      data.drcPassed = false; data.drcIncomplete = false;
      data.drcErrors = 0; data.drcWarnings = 0; data.drcScope = '';
    } else if (data.drcIncomplete || data.drcErrors > 0) data.drcPassed = false;
    return data;
  } catch (_error) { return defaultFormSnapshot(); }
}

const SNAPSHOT_KEY: string = 'card_snapshot_v1';
const IDS_KEY: string = 'card_ids_v1';
export class FormUpdater {
  private static work: Promise<void> = Promise.resolve();
  private static generation: number = 0;
  private static latest: FormSnapshot = defaultFormSnapshot();
  private static committedIdentity: string = '';
  private static committedGeneration: number = 0;
  private static getPreferences(context: Context): preferences.Preferences {
    return preferences.getPreferencesSync(context, { name: 'hongtu_cards' });
  }
  static read(context: Context): FormSnapshot {
    try { return parseFormSnapshot(FormUpdater.getPreferences(context).getSync(SNAPSHOT_KEY, '') as string); }
    catch (_error) { return defaultFormSnapshot(); }
  }
  private static ids(prefs: preferences.Preferences): string[] {
    try {
      const raw = JSON.parse(prefs.getSync(IDS_KEY, '[]') as string) as string[];
      if (!Array.isArray(raw)) return [];
      return raw.filter((id: string, index: number): boolean => typeof id === 'string' &&
        /^[0-9]{1,64}$/.test(id) && raw.indexOf(id) === index);
    } catch (_error) { return []; }
  }
  private static enqueue(action: () => Promise<void>): Promise<void> {
    const next: Promise<void> = FormUpdater.work.then(action);
    FormUpdater.work = next.catch((error: Object) => console.warn(`卡片同步失败：${String(error)}`));
    return FormUpdater.work;
  }
  static register(formId: string, context: Context): Promise<void> {
    return FormUpdater.enqueue(async (): Promise<void> => {
      if (!/^[0-9]{1,64}$/.test(formId)) return;
      const prefs = FormUpdater.getPreferences(context);
      const ids: string[] = FormUpdater.ids(prefs);
      if (ids.indexOf(formId) < 0) { ids.push(formId); prefs.putSync(IDS_KEY, JSON.stringify(ids)); await prefs.flush(); }
      await FormUpdater.deliver(formId, context);
    });
  }
  static remove(formId: string, context: Context): Promise<void> {
    return FormUpdater.enqueue(async (): Promise<void> => {
      const prefs = FormUpdater.getPreferences(context);
      prefs.putSync(IDS_KEY, JSON.stringify(FormUpdater.ids(prefs).filter((id: string): boolean => id !== formId)));
      await prefs.flush();
    });
  }
  private static normalizeSnapshotObject(candidate: FormSnapshot): FormSnapshot {
    const data: FormSnapshot = cloneStructured(candidate);
    if (data.version !== 1 || typeof data.fileName !== 'string' || typeof data.fileType !== 'string' ||
      typeof data.documentId !== 'string' || typeof data.contextIdentity !== 'string' ||
      !Number.isFinite(data.fileSize) || data.fileSize < 0 ||
      !Number.isInteger(data.drcErrors) || data.drcErrors < 0 ||
      !Number.isInteger(data.drcWarnings) || data.drcWarnings < 0 ||
      typeof data.drcChecked !== 'boolean' || typeof data.drcIncomplete !== 'boolean' ||
      typeof data.drcPassed !== 'boolean' || typeof data.drcScope !== 'string' || typeof data.updateTime !== 'string') {
      return defaultFormSnapshot();
    }
    if (!data.drcChecked) {
      data.drcPassed = false;
      data.drcIncomplete = false;
      data.drcErrors = 0;
      data.drcWarnings = 0;
      data.drcScope = '';
    } else if (data.drcIncomplete || data.drcErrors > 0) {
      data.drcPassed = false;
    }
    return data;
  }

  /** Coalesce new inputs and serialize persistence via TaskPool, IPC and retries. */
  static publish(snapshot: FormSnapshot, context: Context): Promise<void> {
    const owned: FormSnapshot = FormUpdater.normalizeSnapshotObject(snapshot);
    owned.updateTime = '';
    const identity: string = `${owned.version}|${owned.documentId}|${owned.contextIdentity}|${owned.fileName}|${owned.fileType}|${owned.fileSize}|${owned.drcChecked}|${owned.drcIncomplete}|${owned.drcPassed}|${owned.drcErrors}|${owned.drcWarnings}|${owned.drcScope}`;
    if (identity === FormUpdater.committedIdentity && FormUpdater.generation === FormUpdater.committedGeneration) return FormUpdater.work;
    FormUpdater.latest = owned;
    const generation: number = ++FormUpdater.generation;
    return FormUpdater.enqueue(async (): Promise<void> => {
      if (generation !== FormUpdater.generation) return;
      const prefs = FormUpdater.getPreferences(context);
      const previous: string = prefs.getSync(SNAPSHOT_KEY, '') as string;
      const data: FormSnapshot = cloneStructured(FormUpdater.latest);
      data.updateTime = new Date().toLocaleTimeString();
      const encodedRes = await layoutConcurrencyService.encodeJsonWithBudgetAsync(
        data,
        64 * 1024,
        'form-card-snapshot'
      );
      const text: string = encodedRes.encoded;
      try {
        prefs.putSync(SNAPSHOT_KEY, text); await prefs.flush();
        if (prefs.getSync(SNAPSHOT_KEY, '') !== text) throw new Error('卡片快照写入不完整');
      } catch (error) {
        prefs.putSync(SNAPSHOT_KEY, previous); await prefs.flush(); throw new Error(String(error));
      }
      FormUpdater.committedIdentity = identity;
      FormUpdater.committedGeneration = generation;
      if (generation !== FormUpdater.generation) return;
      for (const id of FormUpdater.ids(prefs)) await FormUpdater.deliver(id, context);
    });
  }
  private static async deliver(formId: string, context: Context): Promise<void> {
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        const prefs = FormUpdater.getPreferences(context);
        if (FormUpdater.ids(prefs).indexOf(formId) < 0) return;
        await formProvider.updateForm(formId, formBindingData.createFormBindingData(FormUpdater.read(context)));
        return;
      } catch (error) {
        if (attempt === 2) console.warn(`卡片 ${formId} 更新未完成：${String(error)}`);
        else await new Promise<void>((resolve: () => void) => setTimeout(resolve, 200 * Math.pow(2, attempt)));
      }
    }
  }
  static refresh(formId: string, context: Context): Promise<void> { return FormUpdater.register(formId, context); }
}
