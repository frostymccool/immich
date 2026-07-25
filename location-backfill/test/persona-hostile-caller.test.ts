/**
 * Persona C — "The curious/hostile LAN caller"
 *
 * Anything else on the docker network can reach this container's ports: another
 * service probing endpoints, a misconfigured client, or just someone with curl.
 * This persona stress-tests the HTTP surface in index.ts/app.ts — auth boundaries,
 * malformed input, and that the process survives being poked at.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import request from 'supertest';
import { app } from '../src/app.js';

test('GET /healthz requires no secret — the Docker healthcheck depends on this staying open', async () => {
  const res = await request(app).get('/healthz');
  assert.equal(res.status, 200);
});

test('POST /sweep without the secret header is rejected', async () => {
  const res = await request(app).post('/sweep');
  assert.equal(res.status, 401);
});

test('POST /sweep with the wrong secret is rejected', async () => {
  const res = await request(app).post('/sweep').set('x-webhook-secret', 'wrong');
  assert.equal(res.status, 401);
});

test('GET /selftest without the secret header is rejected', async () => {
  const res = await request(app).get('/selftest');
  assert.equal(res.status, 401);
});

test('GET /preview/:id without the secret header is rejected', async () => {
  const res = await request(app).get('/preview/some-id');
  assert.equal(res.status, 401);
});

test('POST /webhook without the secret header is rejected', async () => {
  const res = await request(app).post('/webhook').send({ asset: { id: 'x' } });
  assert.equal(res.status, 401);
});

test('malformed JSON body does not crash the server', async () => {
  const res = await request(app)
    .post('/webhook')
    .set('Content-Type', 'application/json')
    .set('x-webhook-secret', 'test')
    .send('{ this is not valid json');

  // Express's body-parser rejects it before our handler ever runs; the exact status
  // is body-parser's choice, but it must not be a raw crash (5xx from an unhandled
  // exception taking the process down) — proven by the server still answering after.
  assert.ok(res.status >= 400 && res.status < 500, `expected a 4xx, got ${res.status}`);

  const stillAlive = await request(app).get('/healthz');
  assert.equal(stillAlive.status, 200, 'the process must still be serving requests after a bad body');
});

test('GET /preview/:id with a real backend failure returns JSON, not a crash', async () => {
  // IMMICH_URL is set to an unreachable host in the test env — this exercises a real
  // network failure through processAsset, not a mock, and confirms the route's
  // catch handler turns it into a clean response instead of an unhandled rejection.
  const res = await request(app).get('/preview/does-not-exist').set('x-webhook-secret', 'test');
  assert.equal(res.status, 500);
  assert.ok(res.body.error, 'must return a JSON body describing the failure');

  const stillAlive = await request(app).get('/healthz');
  assert.equal(stillAlive.status, 200);
});
