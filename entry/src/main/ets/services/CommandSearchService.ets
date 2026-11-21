/** Task names and availability are shared by the command palette and its host. */
export interface WorkbenchCommand {
  id: string;
  title: string;
  aliases: string;
  shortcut: string;
  enabled: boolean;
  reason: string;
  nextStep: string;
}

export function searchWorkbenchCommands(commands: WorkbenchCommand[], query: string): WorkbenchCommand[] {
  const terms: string[] = query.trim().toLocaleLowerCase().split(/\s+/).filter((term: string) => term.length > 0);
  return commands.filter((command: WorkbenchCommand): boolean => {
    const haystack: string = `${command.title} ${command.aliases} ${command.shortcut}`.toLocaleLowerCase();
    return terms.every((term: string): boolean => haystack.includes(term));
  }).sort((a: WorkbenchCommand, b: WorkbenchCommand): number => {
    if (a.enabled !== b.enabled) return a.enabled ? -1 : 1;
    return 0;
  });
}
