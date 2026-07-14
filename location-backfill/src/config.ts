function required(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

export const config = {
  immichUrl: required('IMMICH_URL'),
  immichApiKey: required('IMMICH_API_KEY'),
  webhookSecret: required('WEBHOOK_SECRET'),
  port: Number(process.env.PORT ?? 8080),
  matchWindowMinutes: Number(process.env.MATCH_WINDOW_MINUTES ?? 60),
  sweepSchedule: process.env.SWEEP_SCHEDULE ?? '0 3 * * *',
  skipSweepIfUploadedWithinMinutes: Number(process.env.SKIP_SWEEP_IF_UPLOADED_WITHIN_MINUTES ?? 30),
};
