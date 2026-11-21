import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

/** Secrets remain in the OS asset store; ordinary application preferences contain no key. */
class CredentialStore {
  private bytes(value: string): Uint8Array {
    return new util.TextEncoder().encodeInto(value);
  }

  async get(alias: string): Promise<string> {
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.ALIAS, this.bytes(alias));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const results: asset.AssetMap[] = await asset.query(query);
      if (results.length === 0) return '';
      const secret: asset.Value | undefined = results[0].get(asset.Tag.SECRET);
      if (!(secret instanceof Uint8Array)) throw new Error('系统凭据格式无效');
      return util.TextDecoder.create('utf-8').decodeWithStream(secret);
    } catch (error) {
      if ((error as BusinessError).code === 24000002) return '';
      throw new Error(`无法读取系统凭据库（${(error as BusinessError).code}）`);
    }
  }

  async put(alias: string, value: string): Promise<void> {
    const attributes: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    attributes.set(asset.Tag.ALIAS, this.bytes(alias));
    if (value.length === 0) {
      try { await asset.remove(attributes); } catch (error) {
        if ((error as BusinessError).code !== 24000002) throw new Error(`无法删除系统凭据（${(error as BusinessError).code}）`);
      }
      return;
    }
    attributes.set(asset.Tag.SECRET, this.bytes(value));
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED);
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    try { await asset.add(attributes); } catch (error) {
      // Do not surface an SDK error body which may include submitted attributes.
      throw new Error(`无法保存系统凭据（${(error as BusinessError).code}）`);
    }
  }
}

export const credentialStore = new CredentialStore();
