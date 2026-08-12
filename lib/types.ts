export type Environment = 'dev' | 'stage' | 'prod';

export interface RouteRegistration {
  hostname: string;
  asg: string;
  port: number;
  healthPath: string;
  healthyStatuses: number[];
  autoHeal: boolean;
}
