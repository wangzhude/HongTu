import { PortEndpoint, ResolvedPort } from './LayoutPort';
export interface PortUiChoice { label: string; endpoint: PortEndpoint; resolved: ResolvedPort; }
export interface PortChoiceList { choices: PortUiChoice[]; truncated: boolean; }
/** Query complete definitions before bounding displayed occurrences. */
export interface PortChoiceQuery {
  scope?: 'all' | 'definition' | 'instance';
  query?: string;
  preferredEndpoint?: PortEndpoint;
}
