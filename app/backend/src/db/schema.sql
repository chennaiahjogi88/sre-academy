-- SRE Training Platform Schema

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Users
CREATE TABLE IF NOT EXISTS users (
  id SERIAL PRIMARY KEY,
  email VARCHAR(255) UNIQUE NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  name VARCHAR(255) NOT NULL,
  role VARCHAR(20) NOT NULL DEFAULT 'student',
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  last_login TIMESTAMPTZ
);

-- Sessions
CREATE TABLE IF NOT EXISTS sessions (
  id SERIAL PRIMARY KEY,
  user_id INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_jti VARCHAR(100) NOT NULL UNIQUE,
  ip_address INET,
  user_agent TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  expires_at TIMESTAMPTZ NOT NULL,
  revoked BOOLEAN DEFAULT FALSE
);
CREATE INDEX IF NOT EXISTS idx_sessions_token_jti ON sessions(token_jti);
CREATE INDEX IF NOT EXISTS idx_sessions_user_id ON sessions(user_id);

-- Class progress
CREATE TABLE IF NOT EXISTS class_progress (
  id SERIAL PRIMARY KEY,
  user_id INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  class_id VARCHAR(50) NOT NULL,
  current_slide INT DEFAULT 0,
  total_slides INT DEFAULT 0,
  completed BOOLEAN DEFAULT FALSE,
  first_viewed TIMESTAMPTZ DEFAULT NOW(),
  last_viewed TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(user_id, class_id)
);

-- Recordings
CREATE TABLE IF NOT EXISTS recordings (
  id SERIAL PRIMARY KEY,
  class_id VARCHAR(50) NOT NULL,
  title VARCHAR(255) NOT NULL,
  description TEXT,
  filename VARCHAR(255),
  original_filename VARCHAR(255),
  file_size BIGINT,
  duration_seconds INT,
  uploaded_by INT REFERENCES users(id),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  is_published BOOLEAN DEFAULT TRUE
);

-- Announcements
CREATE TABLE IF NOT EXISTS announcements (
  id SERIAL PRIMARY KEY,
  title VARCHAR(255) NOT NULL,
  message TEXT NOT NULL,
  type VARCHAR(20) DEFAULT 'info',
  created_by INT REFERENCES users(id),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  expires_at TIMESTAMPTZ,
  is_active BOOLEAN DEFAULT TRUE
);

-- Seed: default admin (password: Admin@123)
INSERT INTO users (email, password_hash, name, role)
VALUES (
  'admin@ktech.sre',
  '$2a$10$oOYuj3WAvUmiNuJ4uJNDaujoNJ9xSFvQaffbZQ5oHd8VqGnZS73X6',
  'Ktech Admin',
  'admin'
) ON CONFLICT (email) DO NOTHING;

-- Seed: demo student (password: Student@123)
INSERT INTO users (email, password_hash, name, role)
VALUES (
  'student@ktech.sre',
  '$2a$10$6UUiy6eV16dnEPS7d8VGwuo5JKEtwP0ZF3J3qpfxjGcs6JbnCYtAm',
  'Demo Student',
  'student'
) ON CONFLICT (email) DO NOTHING;

-- Class delivery status (admin-controlled batch delivery state)
CREATE TABLE IF NOT EXISTS class_delivery_status (
  class_id VARCHAR(50) PRIMARY KEY,
  status VARCHAR(20) NOT NULL DEFAULT 'upcoming',
  updated_by INT REFERENCES users(id),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
