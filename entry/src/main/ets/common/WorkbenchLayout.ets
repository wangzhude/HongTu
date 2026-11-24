import { getAspectClass, getWidthClass, shouldUseDualColumnLayout } from '../store/ResponsiveStore';

/** Panel placement uses available content width AND aspect ratio (square foldables avoid cramped dual columns). */
export interface WorkbenchPanelPlacement {
  sidebarOverlay: boolean;
  inspectorOverlay: boolean;
}

export function boundedPanelWidth(value: number, minimum: number, maximum: number, fallback: number): number {
  return Number.isFinite(value) ? Math.max(minimum, Math.min(maximum, value)) : fallback;
}

export function workbenchPanelPlacement(
  windowWidth: number,
  railWidth: number,
  sidebarWidth: number,
  inspectorWidth: number,
  sidebarVisible: boolean,
  inspectorPinned: boolean,
  windowHeight: number = 0
): WorkbenchPanelPlacement {
  const available: number = Math.max(0, windowWidth - railWidth);
  const allowMultiColumn: boolean = windowHeight > 0
    ? shouldUseDualColumnLayout(getWidthClass(windowWidth), getAspectClass(windowWidth, windowHeight))
    : true;
  const sidebarOverlay: boolean = !allowMultiColumn || available < sidebarWidth + 440;
  const contentWidth: number = available - (sidebarVisible && !sidebarOverlay ? sidebarWidth : 0);
  const inspectorOverlay: boolean = !allowMultiColumn || !inspectorPinned || contentWidth < inspectorWidth + 460;
  return { sidebarOverlay, inspectorOverlay };
}
