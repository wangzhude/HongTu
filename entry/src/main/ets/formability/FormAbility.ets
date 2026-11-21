/**
 * 鸿图桌面服务卡片生命周期：支持初始真实快照投递、定时更新与卡片内点按即时刷新（onFormEvent）。
 *
 * 官方规范依据：
 * - FormExtensionAbility / postCardAction：https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-postcardaction
 *
 * This file is part of HongTu, licensed under GPLv3.
 */
import { Want } from '@kit.AbilityKit';
import { formBindingData, FormExtensionAbility, formInfo } from '@kit.FormKit';
import { FormUpdater } from '../services/FormUpdateService';

export default class FormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId: string = (want.parameters?.[formInfo.FormParam.IDENTITY_KEY] as string) ?? '';
    FormUpdater.register(formId, this.context);
    const data = FormUpdater.read(this.context);
    return formBindingData.createFormBindingData({
      documentId: data.documentId,
      fileName: data.fileName,
      fileType: data.fileType,
      fileSize: data.fileSize,
      drcErrors: data.drcErrors,
      drcWarnings: data.drcWarnings,
      drcPassed: data.drcPassed,
      drcChecked: data.drcChecked,
      drcIncomplete: data.drcIncomplete,
      drcScope: data.drcScope,
      updateTime: data.updateTime,
      formDimension: Number(want.parameters?.[formInfo.FormParam.DIMENSION_KEY] ?? 2),
    });
  }

  onUpdateForm(formId: string): void {
    FormUpdater.refresh(formId, this.context);
  }

  onFormEvent(formId: string, _message: string): void {
    // 响应卡片右上角刷新按钮触发的 postCardAction({ action: 'message' })，无需拉起前台即可刷新快照
    FormUpdater.refresh(formId, this.context);
  }

  onRemoveForm(formId: string): void {
    FormUpdater.remove(formId, this.context);
  }

  onAcquireFormState(_want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }
}
