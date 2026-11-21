import { StableSegmentButton } from '../StableSegmentButton';
import { SegmentButtonItemTuple, SegmentButtonTextItem } from '@kit.ArkUI';
import { COLORS } from '../../common/constants';
import { FONT_MONO } from '../../common/Fonts';
import { DrcIssue } from '../../workbench/WorkbenchModels';
import { drcService } from '../../services/DrcService';
import type { DrcGroupSummary, DrcRuleGroup, DrcNoticeRow } from '../../services/DrcService';
import { WorkbenchSegment } from '../segments/WorkbenchSegment';
import { UI } from '../../common/UiTokens';
import { feedbackCurve, motionDuration, MOTION, panelTransition } from '../../common/Motion';
import { hongTuThemeState } from '../../store/ThemeStore';
import { DrawnStatusIcon } from '../DrawnStatusIcon';
import { WorkbenchIcon } from './WorkbenchIcon';

/** Desktop verification results dock with optical floating glass and pure vector status emblems. */
@Component
export struct DrcResultsDock {
  @Prop @Watch('refreshGroups') issues: DrcIssue[] = [];
  @Prop highlightedViolationId: number = -1;
  @Prop lastDrcElapsed: number = 0;
  @Prop @Watch('refreshGroups') hasRun: boolean = false;
  @Prop collapsed: boolean = false;
  @Prop exportRdbEnabled: boolean = false;
  @Prop exportRdbBusy: boolean = false;
  @State severityFilter: string = 'all';
  @State displayByRule: boolean = false;
  @State noticesExpanded: boolean = false;
  @State groupRanOnce: boolean = false;
  @State groupRows: DrcRuleGroup[] = [];
  @State groupUnknown: DrcRuleGroup[] = [];
  @State groupNotices: DrcNoticeRow[] = [];
  @State groupHitRules: number = 0;
  @State groupZeroHitRules: number = 0;
  @State groupRuleViolations: number = 0;
  @State groupErrors: number = 0;
  @State groupWarnings: number = 0;
  @State groupPassed: boolean = true;
  @State groupScopeNote: string = '';
  @State selectedRuleId: string = '';
  @State groupStatus: string = '';
  runDrcAction: () => void = () => {};
  exportRdbAction: () => void = () => {};
  locateIssueAction: (issue: DrcIssue) => void = () => {};
  openRulesAction: () => void = () => {};
  toggleCollapsedAction: () => void = () => {};

  aboutToAppear(): void {
    this.refreshGroups();
  }

  refreshGroups(): void {
    const summary: DrcGroupSummary | null = this.hasRun ? drcService.getRuleGroups() : null;
    this.selectedRuleId = '';
    this.groupStatus = '';
    if (summary === null) {
      this.groupRanOnce = false;
      this.groupRows = [];
      this.groupUnknown = [];
      this.groupNotices = [];
      this.groupHitRules = 0;
      this.groupZeroHitRules = 0;
      this.groupRuleViolations = 0;
      this.groupErrors = 0;
      this.groupWarnings = 0;
      this.groupPassed = true;
      this.groupScopeNote = '';
      return;
    }
    this.groupRanOnce = true;
    this.groupRows = summary.groups;
    this.groupUnknown = summary.unknown;
    this.groupNotices = summary.notices;
    this.groupHitRules = summary.hitRuleCount;
    this.groupZeroHitRules = summary.zeroHitRuleCount;
    this.groupRuleViolations = summary.ruleViolationCount;
    this.groupErrors = summary.errorCount;
    this.groupWarnings = summary.warningCount;
    this.groupPassed = summary.passed;
    this.groupScopeNote = summary.scopeNote;
  }

  private locateRule(group: DrcRuleGroup): void {
    this.selectedRuleId = group.ruleId;
    if (group.hits === 0) {
      this.groupStatus = group.enabled ? `「${group.ruleName}」本次零命中` : `「${group.ruleName}」未启用`;
      return;
    }
    let issue: DrcIssue | undefined = this.issues.find((item: DrcIssue) => item.ruleId === group.ruleId);
    if (issue === undefined) {
      const matchingGroups: DrcRuleGroup[] = this.groupRows.concat(this.groupUnknown)
        .filter((item: DrcRuleGroup) => item.ruleName === group.ruleName);
      if (matchingGroups.length === 1) {
        issue = this.issues.find((item: DrcIssue) => !item.ruleId && item.ruleName === group.ruleName);
      }
    }
    if (issue === undefined) {
      this.groupStatus = `未找到「${group.ruleName}」的对应问题，请重新检查`;
      return;
    }
    this.groupStatus = '';
    this.locateIssueAction(issue);
  }

  private noticeSummary(): string {
    return this.groupNotices.map((notice: DrcNoticeRow) => notice.title).join('；');
  }

  private dockHeight(): number {
    if (this.collapsed) {
      return 52;
    }
    return 264 + (this.groupNotices.length > 0 ? (this.noticesExpanded ? 92 : 34) : 0);
  }

  private count(severity: string): number {
    return this.issues.filter((issue: DrcIssue) => severity === 'all' || issue.severity === severity).length;
  }

  private filteredIssues(): DrcIssue[] {
    return this.issues.filter((issue: DrcIssue) => this.severityFilter === 'all' || issue.severity === this.severityFilter);
  }

  private emptyTitle(): string {
    if (!this.hasRun) {
      return '尚未检查';
    }
    return this.issues.length === 0 ? '未发现违例' : '当前筛选无违例';
  }

  @Builder
  private NoticeDetailsBlock() {
    Column({ space: 6 }) {
      ForEach(this.groupNotices, (notice: DrcNoticeRow) => {
        Text(`${notice.title}：${notice.message}`)
          .fontSize(11)
          .fontColor(COLORS.warning)
          .lineHeight(17)
          .width('100%')
      }, (notice: DrcNoticeRow) => `${notice.ruleId}-${notice.title}`)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 8, bottom: 8 })
    .backgroundColor(COLORS.surfaceMuted)
    .borderRadius(UI.controlRadius)
    .margin({ top: 4, bottom: 4 })
    .transition(panelTransition(TransitionEdge.TOP))
  }

  @Builder
  private IssueRow(issue: DrcIssue) {
    Row({ space: 10 }) {
      Row({ space: 6 }) {
        DrawnStatusIcon({
          kind: issue.severity === 'error' ? 'error' : (issue.severity === 'warning' ? 'warning' : 'active'),
          iconSize: 16,
          strokeColor: issue.severity === 'error' ? COLORS.danger : (issue.severity === 'warning' ? COLORS.warning : COLORS.muted),
          showSoftPlate: true
        })
        Text(issue.severity === 'error' ? '错误' : (issue.severity === 'warning' ? '警告' : '提示'))
          .fontSize(12)
          .fontColor(issue.severity === 'error' ? COLORS.danger : (issue.severity === 'warning' ? COLORS.warning : COLORS.muted))
      }
      .width(74)
      Text(issue.ruleName).fontSize(12).fontColor(COLORS.ink).width(128).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(issue.layerName).fontSize(12).fontColor(COLORS.ink).width(96).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(issue.message).fontSize(12).fontColor(COLORS.ink).layoutWeight(1).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(`${Math.round(issue.x * 1000) / 1000}, ${Math.round(issue.y * 1000) / 1000}`)
        .fontSize(11)
        .fontFamily(FONT_MONO)
        .fontColor(COLORS.ink)
        .width(150)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(UI.rowHeight)
    .padding({ left: 14, right: 14 })
    .borderRadius(UI.controlRadius)
    .backgroundColor(this.highlightedViolationId === issue.id ? COLORS.primarySoft : Color.Transparent)
    .onClick(() => this.locateIssueAction(issue))
  }

  @Builder
  private RuleRow(group: DrcRuleGroup) {
    Row({ space: 10 }) {
      Text(group.ruleName).fontSize(12).fontColor(COLORS.ink).layoutWeight(1).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(group.typeText).fontSize(11).fontColor(COLORS.muted).width(88).maxLines(1)
      Text(group.layerText).fontSize(11).fontColor(COLORS.ink).width(132).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(group.limitText).fontSize(11).fontColor(COLORS.ink).fontFamily(FONT_MONO).width(106).maxLines(1)
      Text(group.enabled ? `${group.hits}` : '未启用')
        .fontSize(12)
        .fontColor(group.errors > 0 ? COLORS.danger : (group.hits > 0 ? COLORS.warning : COLORS.muted))
        .width(64)
        .textAlign(TextAlign.End)
      Text(`${group.errors} / ${group.warnings}`).fontSize(11).fontColor(COLORS.muted).width(82).textAlign(TextAlign.End)
    }
    .width('100%')
    .height(UI.rowHeight)
    .padding({ left: 14, right: 14 })
    .borderRadius(UI.controlRadius)
    .backgroundColor(this.selectedRuleId === group.ruleId ? COLORS.primarySoft : Color.Transparent)
    .onClick(() => this.locateRule(group))
  }

  @Builder
  private RuleResults() {
    if (this.groupRanOnce) {
      Row({ space: 10 }) {
        Text('规则').fontSize(11).fontColor(COLORS.muted).layoutWeight(1)
        Text('类型').fontSize(11).fontColor(COLORS.muted).width(88)
        Text('图层').fontSize(11).fontColor(COLORS.muted).width(132)
        Text('阈值').fontSize(11).fontColor(COLORS.muted).width(106)
        Text('命中').fontSize(11).fontColor(COLORS.muted).width(64).textAlign(TextAlign.End)
        Text('错误 / 警告').fontSize(11).fontColor(COLORS.muted).width(82).textAlign(TextAlign.End)
      }
      .width('100%')
      .height(30)
      .padding({ left: 22, right: 22 })
      List() {
        if (this.noticesExpanded && this.groupNotices.length > 0) {
          ListItem() {
            this.NoticeDetailsBlock()
          }
        }
        ForEach(this.groupRows, (group: DrcRuleGroup) => {
          ListItem() {
            this.RuleRow(group)
          }
        }, (group: DrcRuleGroup) => group.ruleId)
        if (this.groupUnknown.length > 0) {
          ListItem() {
            Text('未在册规则')
              .fontSize(10).fontColor(COLORS.muted).height(24).padding({ left: 14 })
          }
          ForEach(this.groupUnknown, (group: DrcRuleGroup) => {
            ListItem() {
              this.RuleRow(group)
            }
          }, (group: DrcRuleGroup) => `unknown-${group.ruleId}`)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .cachedCount(10)
      .padding({ left: 8, right: 8 })
      .divider({ strokeWidth: 0.7, color: COLORS.border, startMargin: 14, endMargin: 14 })
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .clip(true)

      if (this.groupStatus.length > 0 || this.groupScopeNote.length > 0) {
        Text(this.groupStatus.length > 0 ? this.groupStatus : this.groupScopeNote)
          .fontSize(10).fontColor(COLORS.muted).width('100%').height(24)
          .padding({ left: 22, right: 22 }).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    } else {
      Column() {
        Text('尚未检查').fontSize(13).fontColor(COLORS.muted)
      }
      .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
    }
  }

  @Builder
  private IssueResults() {
    Row({ space: 10 }) {
      Text('级别').fontSize(11).fontColor(COLORS.muted).width(74)
      Text('规则').fontSize(11).fontColor(COLORS.muted).width(128)
      Text('图层').fontSize(11).fontColor(COLORS.muted).width(96)
      Text('说明').fontSize(11).fontColor(COLORS.muted).layoutWeight(1)
      Text('位置 / nm').fontSize(11).fontColor(COLORS.muted).width(150)
    }
    .width('100%')
    .height(30)
    .padding({ left: 22, right: 22 })

    if (this.filteredIssues().length > 0 || (this.noticesExpanded && this.groupNotices.length > 0)) {
      List() {
        if (this.noticesExpanded && this.groupNotices.length > 0) {
          ListItem() {
            this.NoticeDetailsBlock()
          }
        }
        if (this.filteredIssues().length > 0) {
          ForEach(this.filteredIssues(), (issue: DrcIssue) => {
            ListItem() {
              this.IssueRow(issue)
            }
          }, (issue: DrcIssue) => issue.key())
        } else {
          ListItem() {
            Column() {
              Text(this.emptyTitle()).fontSize(13).fontColor(COLORS.muted)
            }
            .width('100%')
            .height(96)
            .justifyContent(FlexAlign.Center)
          }
        }
      }
      .width('100%')
      .layoutWeight(1)
      .cachedCount(10)
      .padding({ left: 8, right: 8, bottom: 8 })
      .divider({ strokeWidth: 0.7, color: COLORS.border, startMargin: 14, endMargin: 14 })
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .clip(true)
    } else {
      Column() {
        Text(this.emptyTitle()).fontSize(13).fontColor(COLORS.muted)
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    }
  }

  build() {
    Column() {
      Row({ space: 10 }) {
        Text('验证结果').fontSize(UI.titleSize).fontWeight(FontWeight.Bold).fontColor(COLORS.ink)
        Text(this.hasRun ? (this.groupRanOnce ? `${this.groupRuleViolations} 项违例` : `${this.issues.length} 项问题`) : '尚未检查')
          .fontSize(11)
          .fontColor(COLORS.primary)
          .backgroundColor(COLORS.primarySoft)
          .borderRadius(UI.segmentItemRadius)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        if (this.hasRun) {
          Text(`${this.lastDrcElapsed} ms`).fontSize(11).fontColor(COLORS.muted)
        }
        Blank()
        Button(this.exportRdbBusy ? '导出中…' : '导出 RDB', { type: ButtonType.Normal })
          .fontSize(UI.fontBody).fontColor(COLORS.ink).height(UI.compactControlHeight)
          .padding({ left: 14, right: 14 }).backgroundColor(COLORS.surfaceMuted)
          .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .enabled(this.exportRdbEnabled && !this.exportRdbBusy).onClick(this.exportRdbAction)
        Button('规则设置', { type: ButtonType.Normal })
          .fontSize(UI.fontBody)
          .fontColor(COLORS.ink)
          .height(UI.compactControlHeight)
          .padding({ left: 14, right: 14 })
          .backgroundColor(COLORS.surfaceMuted)
          .border({ width: 1, color: COLORS.border })
          .borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .onClick(this.openRulesAction)
        Button(this.hasRun ? '重新检查' : '开始检查', { type: ButtonType.Normal })
          .fontSize(UI.fontBody)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .height(UI.compactControlHeight)
          .padding({ left: 16, right: 16 })
          .backgroundColor(COLORS.primary)
          .border({ width: 1, color: COLORS.primary }).borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .onClick(this.runDrcAction)
        Button({ type: ButtonType.Circle }) {
          WorkbenchIcon({ name: this.collapsed ? 'chevronUp' : 'chevronDown', iconSize: 16, color: COLORS.ink })
        }
        .width(UI.compactControlHeight)
        .height(UI.compactControlHeight)
        .padding(0)
        .backgroundColor(COLORS.surfaceMuted)
        .accessibilityText(this.collapsed ? '展开验证结果' : '收起验证结果')
        .bindTips(this.collapsed ? '展开验证结果' : '收起验证结果')
        .onClick(this.toggleCollapsedAction)
      }
      .width('100%')
      .height(52)
      .padding({ left: 18, right: 14 })

      if (!this.collapsed) {
        Row({ space: 10 }) {
          if (!this.displayByRule) {
            WorkbenchSegment({
              paletteKey: `${COLORS.primary}:${COLORS.surfaceMuted}:${COLORS.ink}`,
              labels: [`全部 ${this.count('all')}`, `错误 ${this.count('error')}`, `警告 ${this.count('warning')}`],
              current: this.severityFilter === 'error' ? 1 : (this.severityFilter === 'warning' ? 2 : 0),
              onChange: (index: number) => { this.severityFilter = index === 1 ? 'error' : (index === 2 ? 'warning' : 'all'); }
            }).width(280)
          } else {
            Text(this.groupRanOnce ? `${this.groupHitRules} 条命中 · ${this.groupZeroHitRules} 条零命中` : '按规则统计')
              .fontSize(12).fontColor(COLORS.muted).margin({ left: 14 })
            if (this.groupRanOnce) {
              Text(this.groupPassed ? '已执行规则通过' : (this.groupNotices.length > 0 ? '检查不完整' : '存在规则错误'))
                .fontSize(11).fontColor(this.groupPassed ? COLORS.primary : COLORS.danger)
            }
          }
          Blank()
          Row() {
            StableSegmentButton({
              items: [{ text: '问题列表' }, { text: '按规则' }] as [SegmentButtonTextItem, SegmentButtonTextItem] as SegmentButtonItemTuple,
              selectedIndex: this.displayByRule ? 1 : 0,
              onItemClicked: (idx: number) => {
                this.displayByRule = idx === 1;
              },
              fontColor: COLORS.muted,
              selectedFontColor: COLORS.primary,
              capsuleBackgroundColor: COLORS.surfaceMuted,
              selectedBackgroundColor: COLORS.primarySoft,
              fontSizeFp: UI.fontCaption,
              capsuleBorderRadius: UI.controlRadius,
              buttonMinHeight: 30,
              itemMinHeight: 26,
              itemPaddingHorizontal: 10,
              itemPaddingVertical: 4
            })
          }.width(164)
        }
        .width('100%')
        .height(38)
        .padding({ left: 8, right: 14 })
        .border({ width: { bottom: 0.8 }, color: COLORS.border })

        if (this.groupNotices.length > 0) {
          Row({ space: 6 }) {
            DrawnStatusIcon({ kind: 'warning', iconSize: 15, strokeColor: COLORS.warning, showSoftPlate: false })
            Text(`完整性提示 ${this.groupNotices.length} · ${this.noticeSummary()}`)
              .fontSize(11).fontColor(COLORS.warning).layoutWeight(1).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.noticesExpanded ? '收起' : '详情').fontSize(11).fontColor(COLORS.warning).margin({ left: 8 })
          }
          .width('100%').height(34).padding({ left: 22, right: 22 })
          .backgroundColor(COLORS.surfaceMuted)
          .onClick(() => {
            this.getUIContext().animateTo({ duration: motionDuration(MOTION.feedback), curve: feedbackCurve() }, () => {
              this.noticesExpanded = !this.noticesExpanded;
            });
          })
        }

        if (this.displayByRule) {
          this.RuleResults()
        } else {
          this.IssueResults()
          if (this.groupRanOnce && this.groupScopeNote.length > 0) {
            Text(this.groupScopeNote)
              .fontSize(10).fontColor(COLORS.muted).width('100%').height(24)
              .padding({ left: 22, right: 22 }).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
      }
    }
    .width('100%')
    .height(this.dockHeight())
    .attributeModifier(hongTuThemeState.luminousFloatingModifier(UI.panelRadius, 'regular', hongTuThemeState.elevation('lg')))
    .transition(panelTransition(TransitionEdge.BOTTOM))
  }
}
