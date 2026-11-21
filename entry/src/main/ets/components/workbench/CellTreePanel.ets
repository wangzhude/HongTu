/**
 * Cell 层级树数据模型（对齐 KLayout Cells Tab）
 *
 * 树节点由 Index.rebuildCellTree() 从当前文档的 INSTANCE 引用关系构建，
 * 渲染在 WorkbenchSidebar 的 Cell Tab（buildCellsTab / buildCellNodeRow）。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

/** Cell 树节点数据 */
export class CellTreeNode {
  cellId: number;
  cellName: string;
  /** 该 Cell 在父 Cell 中被实例化的次数（根节点为全库被引用次数） */
  referenceCount: number;
  /** 子节点 */
  children: CellTreeNode[];
  /** 是否展开 */
  expanded: boolean;
  /** 层级深度（0=顶层） */
  depth: number;
  /** 树内唯一路径（同一 Cell 可在多处出现，避免 key 冲突） */
  path: string;

  constructor(cellId: number, cellName: string, referenceCount: number = 0,
              depth: number = 0, path: string = '') {
    this.cellId = cellId;
    this.cellName = cellName;
    this.referenceCount = referenceCount;
    this.children = [];
    this.expanded = depth < 2; // 默认展开前两层
    this.depth = depth;
    this.path = path.length > 0 ? path : `${cellId}`;
  }

  key(): string {
    return `${this.path}_${this.depth}`;
  }
}
