/**
 * 鸿图 EntryAbility —— 全屏零白罩沉浸底座、卡片路由解析、外部文件 Want 接入、退后台紧急刷盘通知与一多响应式快照发布
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { UIAbility, AbilityConstant, Want, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window, display, UIContext } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import {
  adaptWorkspace,
  HONGTU_FORCE_DESKTOP_MODE_KEY,
  resolveSystemDensity
} from '../common/WorkspaceAdaptation';
import { ThemeManager } from '../common/Theme';
import { registerFonts } from '../common/Fonts';
import { hongTuThemeState } from '../store/ThemeStore';
import {
  bindResponsiveUIContext,
  clearResponsiveUIContext,
  createResponsiveSnapshot,
  publishResponsiveSnapshot,
  publishFloatingWindowStatus,
  publishSafeAreaInsetsVp,
  registerFoldStatusListener,
  unregisterFoldStatusListener
} from '../store/ResponsiveStore';

export const HONGTU_PENDING_CARD_COMMAND_KEY: string = 'hongtuPendingCardCommand';
export const HONGTU_PENDING_EXTERNAL_URI_KEY: string = 'hongtuPendingExternalUri';
export const HONGTU_BACKGROUND_FLUSH_KEY: string = 'hongtuBackgroundFlushToken';

const SUPPORTED_EXTERNAL_FILE_EXTENSIONS: ReadonlyArray<string> = [
  '.gds', '.gdsii', '.oas', '.oasis', '.cif', '.dxf', '.lyp', '.lyrdb', '.rdb', '.hongtu'
];

export interface PendingCardCommandPayload {
  command: string;
  documentId: string;
  ts: number;
}

export interface PendingExternalUriPayload {
  uri: string;
  action: string;
  ts: number;
}

function isSupportedExternalFileUri(rawUri: string): boolean {
  const clean: string = rawUri.split(/[?#]/)[0].trim();
  if (clean.length === 0) {
    return false;
  }
  let decoded: string = clean;
  try {
    decoded = decodeURIComponent(clean);
  } catch (_err) {
  }
  const lower: string = decoded.toLowerCase();
  for (let i: number = 0; i < SUPPORTED_EXTERNAL_FILE_EXTENSIONS.length; i++) {
    if (lower.endsWith(SUPPORTED_EXTERNAL_FILE_EXTENSIONS[i])) {
      return true;
    }
  }
  return clean.startsWith('file://');
}

export default class EntryAbility extends UIAbility {
  private workspaceWindow: window.Window | undefined;
  private workspaceStage: window.WindowStage | undefined;
  private workspaceUIContext: UIContext | undefined;
  private foldRegistered: boolean = false;
  private wantTokenSeq: number = 0;
  private lastAppliedAppColorMode: ConfigurationConstant.ColorMode | undefined = undefined;
  private sizeListener: (size: window.Size) => void = () => this.applyWorkspaceAdaptation();
  private densityListener: (density: number) => void = () => this.applyWorkspaceAdaptation();
  private foldListener: (status: display.FoldStatus) => void = () => this.applyWorkspaceAdaptation();
  private avoidAreaListener: (options: window.AvoidAreaOptions) => void = () => this.refreshSafeAreaInsets();
  private windowStatusListener: (status: window.WindowStatusType) => void = (status: window.WindowStatusType): void => {
    publishFloatingWindowStatus(status === window.WindowStatusType.FLOATING);
  };

  private syncSystemColorMode(colorMode: ConfigurationConstant.ColorMode | undefined): void {
    if (colorMode === undefined) {
      return;
    }
    const systemDark: boolean = colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    hongTuThemeState.setSystemIsDark(systemDark);
  }

  private syncApplicationColorMode(): void {
    let targetMode: ConfigurationConstant.ColorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    if (hongTuThemeState.themeMode === 'dark') {
      targetMode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } else if (hongTuThemeState.themeMode === 'light') {
      targetMode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    }
    if (this.lastAppliedAppColorMode === targetMode) {
      return;
    }
    try {
      this.context?.getApplicationContext()?.setColorMode(targetMode);
      this.lastAppliedAppColorMode = targetMode;
    } catch (_modeErr) {
    }
  }

  private applySystemBarStyle(isDark: boolean): void {
    if (this.workspaceWindow === undefined) {
      return;
    }
    const bgSolid: string = isDark ? '#0F141B' : '#F2F6FA';
    const contentColor: string = isDark ? '#ECF1F6' : '#111827';
    try {
      this.workspaceWindow.setWindowBackgroundColor(hongTuThemeState.colors?.background ?? bgSolid);
    } catch (_bgErr) {
    }
    this.workspaceWindow.setWindowSystemBarProperties({
      statusBarColor: '#00000000',
      navigationBarColor: '#00000000',
      statusBarContentColor: contentColor,
      navigationBarContentColor: contentColor
    }).catch((): void => {});
  }

  private resolveActiveSystemDensity(): number {
    const screen = display.getDefaultDisplaySync();
    let windowDensity: number = -1;
    if (this.workspaceWindow !== undefined && deviceInfo.sdkApiVersion >= 20) {
      try {
        windowDensity = this.workspaceWindow.getWindowDensityInfo().systemDensity;
      } catch (_err) {
      }
    }
    return resolveSystemDensity(windowDensity, screen.densityPixels);
  }

  /**
   * 合并 TYPE_SYSTEM、TYPE_CUTOUT 与 TYPE_NAVIGATION_INDICATOR 四边动态避让区，换算为 vp 广播至全局。
   */
  private refreshSafeAreaInsets(densityOverride?: number): void {
    const mainWindow: window.Window | undefined = this.workspaceWindow;
    if (mainWindow === undefined) {
      return;
    }
    const density: number = Math.max(0.5, densityOverride ?? this.resolveActiveSystemDensity());
    const types: Array<window.AvoidAreaType> = [
      window.AvoidAreaType.TYPE_SYSTEM,
      window.AvoidAreaType.TYPE_CUTOUT,
      window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR
    ];
    let topPx: number = 0;
    let bottomPx: number = 0;
    let leftPx: number = 0;
    let rightPx: number = 0;
    for (let i: number = 0; i < types.length; i++) {
      try {
        const area: window.AvoidArea = mainWindow.getWindowAvoidArea(types[i]);
        if (area !== undefined) {
          topPx = Math.max(topPx, area.topRect?.height ?? 0);
          bottomPx = Math.max(bottomPx, area.bottomRect?.height ?? 0);
          leftPx = Math.max(leftPx, area.leftRect?.width ?? 0);
          rightPx = Math.max(rightPx, area.rightRect?.width ?? 0);
        }
      } catch (_areaErr) {
      }
    }
    publishSafeAreaInsetsVp({
      top: topPx / density,
      bottom: bottomPx / density,
      left: leftPx / density,
      right: rightPx / density
    });
  }

  private applyWorkspaceAdaptation(): void {
    if (this.workspaceWindow === undefined || this.workspaceStage === undefined) return;
    try {
      const rect: window.Rect = this.workspaceWindow.getWindowProperties().windowRect;
      const systemDensity: number = this.resolveActiveSystemDensity();
      const forceDesktop: boolean = AppStorage.get<boolean>(HONGTU_FORCE_DESKTOP_MODE_KEY) === true;
      const layout = adaptWorkspace(rect.width, rect.height, systemDensity, deviceInfo.deviceType, forceDesktop);
      AppStorage.setOrCreate<boolean>('hongtuDesktopWorkspace', layout.desktop);
      AppStorage.setOrCreate<number>('hongtuWindowDensity', systemDensity);
      hongTuThemeState.updateDisplayDensity(systemDensity);
      this.refreshSafeAreaInsets(systemDensity);
      const widthVp: number = rect.width / Math.max(0.5, systemDensity);
      const heightVp: number = rect.height / Math.max(0.5, systemDensity);
      publishResponsiveSnapshot(createResponsiveSnapshot(widthVp, heightVp, this.workspaceUIContext));
    } catch (error) {
      hilog.warn(0x0000, 'HongTu', '工作台响应式适配更新失败: %{public}s', String(error));
    }
  }

  onConfigurationUpdate(configuration: Configuration): void {
    if (hongTuThemeState.themeMode === 'system') {
      this.syncSystemColorMode(configuration?.colorMode);
    }
    this.applySystemBarStyle(hongTuThemeState.isDark);
    this.applyWorkspaceAdaptation();
  }

  /**
   * 按 HarmonyOS Form Kit router 规范优先解析 `want.parameters['params']` JSON 字符串，
   * 提取 `cardCommand` 与 `documentId`，同时保留顶层字段兼容回退。
   */
  private dispatchCardWant(want: Want | undefined): void {
    const parameters: Record<string, Object> | undefined = want?.parameters;
    if (parameters === undefined) {
      return;
    }
    let cardCommand: string = '';
    let documentId: string = '';

    const rawParams: Object | undefined = parameters['params'];
    if (typeof rawParams === 'string' && rawParams.trim().length > 0) {
      try {
        const parsed: Record<string, Object> = JSON.parse(rawParams) as Record<string, Object>;
        if (parsed !== null && typeof parsed === 'object') {
          const cmdField: Object | undefined = parsed['cardCommand'];
          const docField: Object | undefined = parsed['documentId'];
          if (typeof cmdField === 'string') {
            cardCommand = cmdField.trim();
          }
          if (typeof docField === 'string') {
            documentId = docField.trim();
          }
        }
      } catch (err) {
        hilog.warn(0x0000, 'HongTu', '解析卡片 router params 失败: %{public}s', String(err));
      }
    } else if (rawParams !== undefined && rawParams !== null && typeof rawParams === 'object') {
      const paramObj: Record<string, Object> = rawParams as Record<string, Object>;
      const cmdField: Object | undefined = paramObj['cardCommand'];
      const docField: Object | undefined = paramObj['documentId'];
      if (typeof cmdField === 'string') {
        cardCommand = cmdField.trim();
      }
      if (typeof docField === 'string') {
        documentId = docField.trim();
      }
    }

    if (cardCommand.length === 0) {
      const topCmd: Object | undefined = parameters['cardCommand'];
      if (typeof topCmd === 'string') {
        cardCommand = topCmd.trim();
      }
    }
    if (documentId.length === 0) {
      const topDoc: Object | undefined = parameters['documentId'];
      if (typeof topDoc === 'string') {
        documentId = topDoc.trim();
      }
    }

    if (cardCommand.length > 0) {
      const payload: PendingCardCommandPayload = {
        command: cardCommand,
        documentId: documentId,
        ts: Date.now() * 100 + (++this.wantTokenSeq % 100)
      };
      AppStorage.setOrCreate<string>(HONGTU_PENDING_CARD_COMMAND_KEY, JSON.stringify(payload));
    }
  }

  /**
   * 提取系统文件管理打开（viewData）或系统分享（sendData）携带的版图/工艺层/报告/工程文件 URI，
   * 写入共享待消费状态交由 Index 主工作台安全校验导入。
   */
  private dispatchExternalUriWant(want: Want | undefined): void {
    if (want === undefined) {
      return;
    }
    let candidateUri: string = typeof want.uri === 'string' ? want.uri.trim() : '';
    if (candidateUri.length === 0 && want.parameters !== undefined) {
      const streamObj: Object | undefined = want.parameters['ability.params.stream'];
      if (Array.isArray(streamObj) && streamObj.length > 0 && typeof streamObj[0] === 'string') {
        candidateUri = (streamObj[0] as string).trim();
      } else if (typeof streamObj === 'string') {
        candidateUri = streamObj.trim();
      }
    }
    if (candidateUri.length === 0 || !isSupportedExternalFileUri(candidateUri)) {
      return;
    }
    const payload: PendingExternalUriPayload = {
      uri: candidateUri,
      action: want.action ?? '',
      ts: Date.now() * 100 + (++this.wantTokenSeq % 100)
    };
    AppStorage.setOrCreate<string>(HONGTU_PENDING_EXTERNAL_URI_KEY, JSON.stringify(payload));
  }

  onCreate(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, 'HongTu', '鸿图启动 %{public}s', want?.bundleName ?? '');
    this.syncSystemColorMode(this.context?.config?.colorMode);
    ThemeManager.init();
    this.syncApplicationColorMode();
    hongTuThemeState.onSchemeChanged((isDark: boolean): void => {
      this.syncApplicationColorMode();
      this.applySystemBarStyle(isDark);
    });
    registerFonts(this.context);
    this.dispatchCardWant(want);
    this.dispatchExternalUriWant(want);
  }

  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    this.dispatchCardWant(want);
    this.dispatchExternalUriWant(want);
  }

  /**
   * 应用退入后台时立即广播紧急草稿刷盘信号，防止防抖定时器尚未到期即被系统回收进程。
   */
  onBackground(): void {
    const token: string = `${Date.now()}-${++this.wantTokenSeq}`;
    hilog.info(0x0000, 'HongTu', '鸿图退入后台，触发工作区紧急刷盘 %{public}s', token);
    try {
      AppStorage.setOrCreate<string>(HONGTU_BACKGROUND_FLUSH_KEY, token);
    } catch (err) {
      hilog.warn(0x0000, 'HongTu', '退后台刷盘信号发布失败: %{public}s', String(err));
    }
  }

  onDestroy(): void {
    hilog.info(0x0000, 'HongTu', '鸿图销毁');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.configureImmersiveWindow(windowStage);
  }

  private async configureImmersiveWindow(windowStage: window.WindowStage): Promise<void> {
    try {
      const mainWindow: window.Window = await windowStage.getMainWindow();
      this.workspaceWindow = mainWindow;
      this.workspaceStage = windowStage;
      await mainWindow.setWindowLayoutFullScreen(true);
      hongTuThemeState.bindMainWindow(mainWindow);
      this.applySystemBarStyle(hongTuThemeState.isDark);
      await mainWindow.setWindowSystemBarEnable(['status', 'navigation']);
      try {
        mainWindow.on('avoidAreaChange', this.avoidAreaListener);
      } catch (avoidErr) {
        hilog.warn(0x0000, 'HongTu', '避让区监听注册不可用: %{public}s', String(avoidErr));
      }
      try {
        publishFloatingWindowStatus(mainWindow.getWindowStatus() === window.WindowStatusType.FLOATING);
      } catch (_statusErr) {
        publishFloatingWindowStatus(false);
      }
      try {
        mainWindow.on('windowStatusDidChange', this.windowStatusListener);
      } catch (_statusRegErr) {
      }
      this.foldRegistered = registerFoldStatusListener(this.foldListener);
      this.applyWorkspaceAdaptation();
    } catch (e) {
      hilog.error(0x0000, 'HongTu', '沉浸式窗口底座设置失败: %{public}s', JSON.stringify(e));
    } finally {
      windowStage.loadContent('pages/Index', (err) => {
        if (err.code) {
          hilog.error(0x0000, 'HongTu', '加载页面失败: %{public}s', JSON.stringify(err));
          return;
        }
        hilog.info(0x0000, 'HongTu', '页面加载成功');
        try {
          if (this.workspaceWindow !== undefined) {
            this.workspaceUIContext = this.workspaceWindow.getUIContext();
            bindResponsiveUIContext(this.workspaceUIContext);
          }
        } catch (ctxErr) {
          hilog.warn(0x0000, 'HongTu', '获取窗口 UIContext 失败: %{public}s', String(ctxErr));
        }
        try {
          this.workspaceWindow?.on('windowSizeChange', this.sizeListener);
        } catch (error) {
          hilog.warn(0x0000, 'HongTu', '窗口尺寸监听不可用: %{public}s', String(error));
        }
        if (deviceInfo.sdkApiVersion >= 20) {
          try {
            this.workspaceWindow?.on('systemDensityChange', this.densityListener);
          } catch (error) {
            hilog.warn(0x0000, 'HongTu', '系统密度监听不可用: %{public}s', String(error));
          }
        }
        this.applySystemBarStyle(hongTuThemeState.isDark);
        this.applyWorkspaceAdaptation();
      });
    }
  }

  onWindowStageDestroy(): void {
    if (this.foldRegistered) {
      unregisterFoldStatusListener(this.foldListener);
      this.foldRegistered = false;
    }
    try {
      this.workspaceWindow?.off('avoidAreaChange', this.avoidAreaListener);
    } catch (_avoidErr) {
    }
    try {
      this.workspaceWindow?.off('windowStatusDidChange', this.windowStatusListener);
    } catch (_statusOffErr) {
    }
    try {
      this.workspaceWindow?.off('windowSizeChange', this.sizeListener);
    } catch (error) {
      hilog.warn(0x0000, 'HongTu', '解除窗口尺寸监听失败: %{public}s', String(error));
    }
    if (deviceInfo.sdkApiVersion >= 20) {
      try {
        this.workspaceWindow?.off('systemDensityChange', this.densityListener);
      } catch (error) {
        hilog.warn(0x0000, 'HongTu', '解除系统密度监听失败: %{public}s', String(error));
      }
    }
    clearResponsiveUIContext();
    hongTuThemeState.unbindMainWindow(this.workspaceWindow);
    this.workspaceUIContext = undefined;
    this.workspaceWindow = undefined;
    this.workspaceStage = undefined;
    hilog.info(0x0000, 'HongTu', '窗口销毁');
  }
}
