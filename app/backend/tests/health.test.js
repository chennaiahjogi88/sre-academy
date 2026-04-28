// Tests for /health and /metrics — no database required.
// Mock tracing before loading the app to avoid OTel instrumentation side-effects in tests.
jest.mock('../src/tracing', () => ({}));

const request = require('supertest');
const { app } = require('../src/index');

describe('GET /health', () => {
  test('returns 200 with status ok', async () => {
    const res = await request(app).get('/health');
    expect(res.statusCode).toBe(200);
    expect(res.body.status).toBe('ok');
  });

  test('response includes timestamp and uptime', async () => {
    const res = await request(app).get('/health');
    expect(res.body).toHaveProperty('timestamp');
    expect(typeof res.body.uptime).toBe('number');
    expect(res.body.uptime).toBeGreaterThanOrEqual(0);
  });
});

describe('GET /metrics', () => {
  test('returns 200 with prometheus text format', async () => {
    const res = await request(app).get('/metrics');
    expect(res.statusCode).toBe(200);
    expect(res.headers['content-type']).toMatch(/text\/plain/);
  });

  test('response body contains expected metric names', async () => {
    const res = await request(app).get('/metrics');
    expect(res.text).toMatch(/http_requests_total/);
    expect(res.text).toMatch(/nodejs_version_info/);
  });
});

describe('404 handling', () => {
  test('unknown route returns 404', async () => {
    const res = await request(app).get('/api/does-not-exist');
    expect(res.statusCode).toBe(404);
  });
});
