import cron from 'node-cron';
import { config } from './config.js';
import { app } from './app.js';
import { runSweep } from './sweep.js';

cron.schedule(config.sweepSchedule, () => {
  runSweep().catch((error) => console.error('[sweep] failed:', error));
});

app.listen(config.port, () => {
  console.log(`location-backfill listening on :${config.port}, sweep schedule "${config.sweepSchedule}"`);
});
