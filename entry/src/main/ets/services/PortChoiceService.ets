import { Shape, ShapeType } from '../models/GdsiiData';
import { LayoutPort, PortEndpoint } from '../models/LayoutPort';
import { PortUiChoice, PortChoiceList, PortChoiceQuery } from '../models/PortUiChoice';
import { EditStructureState, InstancePathStep, InstancePathTransform } from './EditService';
import { resolveLayoutPort } from './PortService';
import { Mat2D, instanceTransformMat } from './HierarchyExpandService';

interface PortPathNode { cellId: number; path: InstancePathStep[]; seen: number[]; }
function compose(left: Mat2D, right: Mat2D): Mat2D {
  return { a: left.a * right.a + left.b * right.c, b: left.a * right.b + left.b * right.d,
    c: left.c * right.a + left.d * right.c, d: left.c * right.b + left.d * right.d,
    tx: left.a * right.tx + left.b * right.ty + left.tx, ty: left.c * right.tx + left.d * right.ty + left.ty };
}
/** Query complete definition identities before bounding displayed occurrences.
 * Exact preferred endpoints are re-resolved before the ordinary display cap. */
export function collectPortChoices(shapes: Shape[], structure: EditStructureState, preferredPath: InstancePathStep[] = [],
  limit: number = 2000, options: PortChoiceQuery = {}): PortChoiceList {
  const scope: string = options.scope ?? 'all', query: string = (options.query ?? '').trim().toLocaleLowerCase();
  if (!Number.isInteger(limit) || limit < 1 || limit > 2000 || !['all', 'definition', 'instance'].includes(scope) || query.length > 4096) {
    throw new Error('端口检索范围或显示预算无效');
  }
  const root: number = structure.cellStack[structure.cellStack.length - 1], keys: string[] = structure.cellKeys ?? [];
  const ports: LayoutPort[] = structure.ports ?? [], choices: PortUiChoice[] = [];
  if (ports.length === 0) return { choices: [], truncated: false };
  const byCell: Map<number, Shape[]> = new Map<number, Shape[]>(), byPortCell: Map<number, LayoutPort[]> = new Map<number, LayoutPort[]>();
  for (const shape of shapes) {
    if (shape.type !== ShapeType.INSTANCE) continue; const owner: number = shape.ownerCellId ?? structure.topCellId;
    const items: Shape[] = byCell.get(owner) ?? []; items.push(shape); byCell.set(owner, items);
  }
  const pathQuery: boolean = /[#\[\]›]/.test(query);
  const pathMatch: RegExpExecArray | null = /^#(\d+)(?:\[(\d+),(\d+)\])?$/.exec(query);
  let requestedInstance: number | undefined = pathMatch === null ? undefined : Number(pathMatch[1]);
  for (const port of ports) {
    if ((scope === 'definition' && port.ownerCellId !== root) || (scope === 'instance' && port.ownerCellId === root)) continue;
    const text: string = `${port.name} · ${port.portType} · ${port.layerNumber}/${port.datatype} · ${port.id} · ${structure.cellNames[port.ownerCellId]}`.toLocaleLowerCase();
    if (query.length > 0 && !pathQuery && !text.includes(query) && !`定义 · ${text}`.includes(query) && !`实例 · ${text}`.includes(query)) continue;
    const items: LayoutPort[] = byPortCell.get(port.ownerCellId) ?? []; items.push(port); byPortCell.set(port.ownerCellId, items);
  }
  if (byPortCell.size === 0) return { choices: [], truncated: false };
  // Skip a compressed array entirely when its definition subtree contains no
  // matching ports. Otherwise irrelevant large AREFs consume the visit budget.
  const parents: Map<number, Set<number>> = new Map<number, Set<number>>();
  for (const entry of byCell.entries()) {
    for (const instance of entry[1]) {
      const child: number = instance.cellId ?? -1;
      if (child < 0 || child >= keys.length) continue;
      const owners: Set<number> = parents.get(child) ?? new Set<number>(); owners.add(entry[0]); parents.set(child, owners);
    }
  }
  // An exact name/ID must not be pushed out by 2000 earlier substring matches.
  // Prefer exact definitions only when they are reachable in this current root.
  if (query.length > 0) {
    const exactAncestors: Set<number> = new Set<number>(), exactQueue: number[] = [];
    for (const entry of byPortCell.entries()) {
      if (entry[1].some((port: LayoutPort): boolean => port.name.toLocaleLowerCase() === query || port.id.toLocaleLowerCase() === query)) {
        exactAncestors.add(entry[0]); exactQueue.push(entry[0]);
      }
    }
    for (let index: number = 0; index < exactQueue.length; index++) {
      for (const owner of parents.get(exactQueue[index]) ?? new Set<number>()) {
        if (!exactAncestors.has(owner)) { exactAncestors.add(owner); exactQueue.push(owner); }
      }
    }
    if (exactAncestors.has(root)) {
      // Legal names/IDs may contain #digits or [row,col]. Actual exact
      // definition identity wins over interpreting the text as a path selector.
      requestedInstance = undefined;
      for (const entry of byPortCell.entries()) {
        const exact: LayoutPort[] = entry[1].filter((port: LayoutPort): boolean => port.name.toLocaleLowerCase() === query || port.id.toLocaleLowerCase() === query);
        if (exact.length > 0) byPortCell.set(entry[0], exact); else byPortCell.delete(entry[0]);
      }
    }
  }
  const matchingSubtree: Set<number> = new Set<number>(), ancestorQueue: number[] = [];
  for (const owner of byPortCell.keys()) { matchingSubtree.add(owner); ancestorQueue.push(owner); }
  for (let index: number = 0; index < ancestorQueue.length; index++) {
    for (const owner of parents.get(ancestorQueue[index]) ?? new Set<number>()) {
      if (!matchingSubtree.has(owner)) { matchingSubtree.add(owner); ancestorQueue.push(owner); }
    }
  }
  const instanceAncestors: Set<number> = new Set<number>();
  if (requestedInstance !== undefined) {
    const selected: Shape | undefined = shapes.find((shape: Shape): boolean => shape.type === ShapeType.INSTANCE && shape.id === requestedInstance);
    if (selected === undefined) return { choices: [], truncated: false };
    const owner: number = selected.ownerCellId ?? structure.topCellId, pending: number[] = [owner]; instanceAncestors.add(owner);
    for (let index: number = 0; index < pending.length; index++) {
      for (const parent of parents.get(pending[index]) ?? new Set<number>()) {
        if (!instanceAncestors.has(parent)) { instanceAncestors.add(parent); pending.push(parent); }
      }
    }
  }
  const seenChoices: Set<string> = new Set<string>(); let truncated: boolean = false, compressedArrays: boolean = false, work: number = 0;
  const appendOne = (port: LayoutPort, path: InstancePathStep[]): void => {
      if ((scope === 'definition' && path.length > 0) || (scope === 'instance' && path.length === 0)) return;
      if (++work > 200000) { truncated = true; return; }
      const signature: string = `${port.id}:${path.map((step: InstancePathStep): string => `${step.instanceId}/${step.row}/${step.col}`).join('>')}`;
      if (seenChoices.has(signature)) return;
      const labelScope: string = path.length === 0 ? '定义' : path.map((step: InstancePathStep): string => `#${step.instanceId}[${step.row},${step.col}]`).join(' › ');
      const label: string = `${labelScope} · ${port.name} · ${port.portType} · ${port.layerNumber}/${port.datatype}`;
      if (query.length > 0 && pathQuery && !label.toLocaleLowerCase().includes(query) && !port.id.toLocaleLowerCase().includes(query)) return;
      if (choices.length >= limit) { truncated = true; return; }
      const endpoint: PortEndpoint = { portId: port.id, rootCellId: root, rootCellKey: keys[root], path: path };
      try {
        const resolved = resolveLayoutPort(endpoint, shapes, structure);
        choices.push({ label: label, endpoint: endpoint, resolved: resolved }); seenChoices.add(signature);
      } catch (_) { /* A stale preferred canvas path cannot become an editable endpoint. */ }
  };
  const append = (cellId: number, path: InstancePathStep[]): void => {
    for (const port of byPortCell.get(cellId) ?? []) { appendOne(port, path); if (truncated) return; }
  };
  const preferred: PortEndpoint | undefined = options.preferredEndpoint;
  if (preferred !== undefined && preferred.rootCellId === root && preferred.rootCellKey === keys[root]) {
    const owner: number = preferred.path.length > 0 ? preferred.path[preferred.path.length - 1].cellId : root;
    const port: LayoutPort | undefined = (byPortCell.get(owner) ?? []).find((item: LayoutPort): boolean => item.id === preferred.portId);
    if (port !== undefined) appendOne(port, preferred.path);
  }
  if (scope !== 'instance') append(root, []);
  if (scope !== 'definition' && preferredPath.length > 0 && preferredPath[0].parentCellId === root) append(preferredPath[preferredPath.length - 1].cellId, preferredPath);
  if (scope === 'definition') return { choices: choices, truncated: truncated };
  let visits: number = 0;
  const visit = (node: PortPathNode): void => {
    if (truncated) return;
    if (node.path.length >= 32) { if (byCell.has(node.cellId)) truncated = true; return; }
    const withinRequested: boolean = requestedInstance !== undefined && node.path.some((step: InstancePathStep): boolean => step.instanceId === requestedInstance);
    for (const instance of byCell.get(node.cellId) ?? []) {
      if (truncated) return;
      const child: number = instance.cellId ?? -1; if (child < 0 || child >= keys.length || node.seen.includes(child) || !matchingSubtree.has(child)) continue;
      if (requestedInstance !== undefined && !withinRequested && instance.id !== requestedInstance && !instanceAncestors.has(child)) continue;
      const rows: number = Math.max(1, instance.arrayRows ?? 1), cols: number = Math.max(1, instance.arrayCols ?? 1);
      const override: boolean = instance.id === requestedInstance && pathMatch !== null && pathMatch[2] !== undefined;
      const requestedRow: number = override && pathMatch !== null ? Number(pathMatch[2]) : 0, requestedCol: number = override && pathMatch !== null ? Number(pathMatch[3]) : 0;
      if (override && (!Number.isSafeInteger(requestedRow) || !Number.isSafeInteger(requestedCol) || requestedRow >= rows || requestedCol >= cols)) continue;
      const compressed: boolean = rows * cols > 256;
      if (compressed && !override) compressedArrays = true;
      // One representative preserves access to later instance paths. Concrete
      // array members remain selectable via preferredEndpoint or row/column UI.
      for (let rowIndex: number = 0; rowIndex < (compressed || override ? 1 : rows) && !truncated; rowIndex++) {
        for (let colIndex: number = 0; colIndex < (compressed || override ? 1 : cols) && !truncated; colIndex++) {
          const row: number = override ? requestedRow : rowIndex, col: number = override ? requestedCol : colIndex;
          if (++visits > 12000) { truncated = true; break; }
          const member: Mat2D = instanceTransformMat(instance);
          member.tx += col * (instance.arrayColStepX ?? 0) + row * (instance.arrayRowStepX ?? 0);
          member.ty += col * (instance.arrayColStepY ?? 0) + row * (instance.arrayRowStepY ?? 0);
          const saved: InstancePathTransform | undefined = node.path.length > 0 ? node.path[node.path.length - 1].transform : undefined;
          const parent: Mat2D = { a: saved?.a ?? 1, b: saved?.b ?? 0, c: saved?.c ?? 0,
            d: saved?.d ?? 1, tx: saved?.tx ?? 0, ty: saved?.ty ?? 0 };
          const world: Mat2D = compose(parent, member);
          const transform: InstancePathTransform = { a: world.a, b: world.b, c: world.c, d: world.d, tx: world.tx, ty: world.ty };
          const step: InstancePathStep = { parentCellId: node.cellId, cellId: child, instanceId: instance.id, row: row, col: col, transform: transform };
          const path: InstancePathStep[] = node.path.concat([step]);
          append(child, path); if (!truncated && byCell.has(child)) visit({ cellId: child, path: path, seen: node.seen.concat([child]) });
        }
      }
    }
  };
  visit({ cellId: root, path: [], seen: [root] });
  return { choices: choices, truncated: truncated || compressedArrays };
}
