/** Shared workbench dimensions aligned with Luminous design tokens while preserving dense EDA tool strips. */
import { Radius } from '../store/ThemeStore';

export interface WorkbenchUiTokens {
  controlHeight: number;
  compactControlHeight: number;
  fieldHeight: number;
  fontBody: number;
  fontCaption: number;
  panelPadding: number;
  dialogPadding: number;
  dialogRadius: number;
  controlRadius: number;
  panelRadius: number;
  sectionGap: number;
  titleSize: number;
  titleBarHeight: number;
  railWidth: number;
  sidebarWidth: number;
  rowHeight: number;
  segmentItemRadius: number;
  chipRadius: number;
  focusWidth: number;
  menuMaxDepth: number;
  menuMaxEntries: number;
  menuGroupMaxActions: number;
  menuRowHeight: number;
  menuIconSize: number;
  menuContentPadding: number;
  menuOuterPadding: number;
  menuItemGap: number;
  menuStackArrowSize: number;
}

export const UI: WorkbenchUiTokens = {
  controlHeight: 36,
  compactControlHeight: 32,
  fieldHeight: 40,
  fontBody: 13,
  fontCaption: 11,
  panelPadding: 16,
  dialogPadding: 24,
  dialogRadius: Radius.xl,
  controlRadius: Radius.sm,
  panelRadius: Radius.lg,
  sectionGap: 24,
  titleSize: 18,
  titleBarHeight: 56,
  railWidth: 48,
  sidebarWidth: 218,
  rowHeight: 40,
  segmentItemRadius: Radius.sm,
  chipRadius: Radius.sm,
  focusWidth: 2,
  menuMaxDepth: 2,
  menuMaxEntries: 7,
  menuGroupMaxActions: 7,
  menuRowHeight: 44,
  menuIconSize: 18,
  menuContentPadding: 12,
  menuOuterPadding: 4,
  menuItemGap: 8,
  menuStackArrowSize: 24
};
