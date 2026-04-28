// Tests for /api/auth — database is mocked so no real Postgres needed.
// Both tracing and db are mocked before the app is loaded.
jest.mock('../src/tracing', () => ({}));

const request = require('supertest');

const mockDb = { query: jest.fn() };
jest.mock('../src/db', () => mockDb);

const { app } = require('../src/index');

afterEach(() => jest.clearAllMocks());

// ─────────────────────────────────────────────
// POST /api/auth/login — input validation
// ─────────────────────────────────────────────
describe('POST /api/auth/login', () => {
  test('400 when email is missing', async () => {
    const res = await request(app)
      .post('/api/auth/login')
      .send({ password: 'secret123' });
    expect(res.statusCode).toBe(400);
    expect(res.body.error).toMatch(/required/i);
  });

  test('400 when password is missing', async () => {
    const res = await request(app)
      .post('/api/auth/login')
      .send({ email: 'user@example.com' });
    expect(res.statusCode).toBe(400);
  });

  test('400 when body is empty', async () => {
    const res = await request(app).post('/api/auth/login').send({});
    expect(res.statusCode).toBe(400);
  });

  test('401 when user does not exist in db', async () => {
    mockDb.query.mockResolvedValueOnce({ rows: [] });
    const res = await request(app)
      .post('/api/auth/login')
      .send({ email: 'ghost@example.com', password: 'password123' });
    expect(res.statusCode).toBe(401);
    expect(res.body.error).toMatch(/invalid credentials/i);
  });

  test('401 when account is disabled', async () => {
    mockDb.query.mockResolvedValueOnce({
      rows: [{ id: '1', email: 'user@example.com', name: 'Test', role: 'student',
               password_hash: '$2b$10$invalid', is_active: false }],
    });
    const res = await request(app)
      .post('/api/auth/login')
      .send({ email: 'user@example.com', password: 'password123' });
    expect(res.statusCode).toBe(401);
    expect(res.body.error).toMatch(/disabled/i);
  });
});

// ─────────────────────────────────────────────
// POST /api/auth/register — input validation
// ─────────────────────────────────────────────
describe('POST /api/auth/register', () => {
  test('400 when all fields are missing', async () => {
    const res = await request(app).post('/api/auth/register').send({});
    expect(res.statusCode).toBe(400);
    expect(res.body.message).toMatch(/required/i);
  });

  test('400 when name is missing', async () => {
    const res = await request(app)
      .post('/api/auth/register')
      .send({ email: 'test@example.com', password: 'password123' });
    expect(res.statusCode).toBe(400);
  });

  test('400 when email is missing', async () => {
    const res = await request(app)
      .post('/api/auth/register')
      .send({ name: 'Test User', password: 'password123' });
    expect(res.statusCode).toBe(400);
  });

  test('409 when email is already registered', async () => {
    // First query checks for existing email and finds one
    mockDb.query.mockResolvedValueOnce({ rows: [{ id: 'existing-id' }] });
    const res = await request(app)
      .post('/api/auth/register')
      .send({ name: 'Test User', email: 'taken@example.com', password: 'password123' });
    expect(res.statusCode).toBe(409);
    expect(res.body.message).toMatch(/already exists/i);
  });
});

// ─────────────────────────────────────────────
// GET /api/auth/me — requires valid JWT
// ─────────────────────────────────────────────
describe('GET /api/auth/me', () => {
  test('401 when no token is provided', async () => {
    const res = await request(app).get('/api/auth/me');
    expect(res.statusCode).toBe(401);
  });

  test('401 when token is malformed', async () => {
    const res = await request(app)
      .get('/api/auth/me')
      .set('Authorization', 'Bearer not.a.real.token');
    expect(res.statusCode).toBe(401);
  });
});
