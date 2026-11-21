import type { ParsedCommand } from './AiService';

export interface AiReviewGroup {
  id: string; indexes: number[]; title: string; accepted: boolean; targetIds: number[];
}

/** Split only provably disjoint explicit-target edits. Implicit selection/layer chains stay atomic. */
export function groupAiEdits(commands: ParsedCommand[]): AiReviewGroup[] {
  if (commands.length === 0) return [];
  const seen: Set<number> = new Set<number>();
  const independent: boolean = commands.every((command: ParsedCommand): boolean => {
    if (!['move_shape', 'delete_shape', 'rotate_shape', 'mirror_shape', 'scale_shape'].includes(command.type)) return false;
    const ids: number[] = command.params.shapeIds ?? [];
    if (ids.length === 0 || ids.some((id: number): boolean => seen.has(id))) return false;
    for (const id of ids) seen.add(id);
    return true;
  });
  if (!independent || commands.length > 16) return [{ id: 'batch', indexes: commands.map((_command: ParsedCommand, i: number): number => i),
    title: `${commands.length} 项关联操作（整组应用或取消）`, accepted: true, targetIds: [] }];
  return commands.map((command: ParsedCommand, index: number): AiReviewGroup => ({ id: `group-${index}`, indexes: [index],
    title: command.description || command.type, accepted: true, targetIds: (command.params.shapeIds ?? []).slice() }));
}

export function acceptedAiEdits(commands: ParsedCommand[], groups: AiReviewGroup[]): ParsedCommand[] {
  const indexes: Set<number> = new Set<number>();
  for (const group of groups) if (group.accepted) for (const index of group.indexes) indexes.add(index);
  return commands.filter((_command: ParsedCommand, index: number): boolean => indexes.has(index));
}
