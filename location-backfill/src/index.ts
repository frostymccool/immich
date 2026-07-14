import express from 'express';
import cron from 'node-cron';
import { config } from './config.js';
import { handleWebhook } from './webhook.js';
import { runSweep } from './sweep.js';

const app = express();
app.use(express.json());

app.get('/healthz', (_req, res) => res.sendStatus(200));

app.post('/webhook', (req, res) => {
  void handleWebhook(req, res);
});

app.post('/sweep', (req, res) => {
  if (req.header('x-webhook-secret') !== config.webhookSecret) {
    res.sendStatus(401);
    return;
  }
  // Fire and acknowledge immediately; a full sweep can take a while on a large library.
  res.sendStatus(202);
  runSweep().catch((error) => console.error('[sweep] failed:', error));
});

cron.schedule(config.sweepSchedule, () => {
  runSweep().catch((error) => console.error('[sweep] failed:', error));
});

app.listen(config.port, () => {
  console.log(`location-backfill listening on :${config.port}, sweep schedule "${config.sweepSchedule}"`);
});
