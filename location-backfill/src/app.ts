import express, { type Request, type Response, type NextFunction } from 'express';
import { config } from './config.js';
import { handleWebhook } from './webhook.js';
import { runSweep } from './sweep.js';
import { runSelfTest } from './selftest.js';
import { processAsset } from './backfill.js';

export const app = express();
app.use(express.json());

function requireSecret(req: Request, res: Response, next: NextFunction): void {
  if (req.header('x-webhook-secret') !== config.webhookSecret) {
    res.sendStatus(401);
    return;
  }
  next();
}

// Intentionally open, no secret required: the Docker healthcheck hits this directly.
app.get('/healthz', (_req, res) => res.sendStatus(200));

app.post('/webhook', (req, res) => {
  void handleWebhook(req, res);
});

app.post('/sweep', requireSecret, (_req, res) => {
  // Fire and acknowledge immediately; a full sweep can take a while on a large library.
  res.sendStatus(202);
  runSweep().catch((error) => console.error('[sweep] failed:', error));
});

// Runs the algorithm against synthetic data plus a real connectivity/auth check —
// hit this first after deploying to confirm the container is wired up correctly.
app.get('/selftest', requireSecret, (_req, res) => {
  runSelfTest()
    .then((report) => res.status(report.ok ? 200 : 500).json(report))
    .catch((error) => res.status(500).json({ ok: false, error: String(error) }));
});

// Computes what would happen for a real asset without writing anything back —
// the safe way to try this out against your actual library.
app.get('/preview/:id', requireSecret, (req, res) => {
  processAsset(req.params.id, { dryRun: true })
    .then((result) => res.json(result))
    .catch((error) => res.status(500).json({ error: String(error) }));
});
