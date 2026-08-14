export type Environment = 'dev' | 'stage' | 'prod';

export interface RouteRegistration {
  hostname: string;
  /** Optional private Route 53 name accepted only by the internal frontend. */
  internalHostname?: string;
  asg: string;
  port: number;
  healthPath: string;
  healthyStatuses: number[];
  autoHeal: boolean;
}
