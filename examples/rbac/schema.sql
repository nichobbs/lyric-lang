-- examples/rbac/schema.sql
-- RBAC schema for PostgreSQL.
--
-- Apply:  psql -d rbac -f examples/rbac/schema.sql

-- Users
CREATE TABLE users (
    id         BIGSERIAL PRIMARY KEY,
    username   TEXT        NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Roles
CREATE TABLE roles (
    id          BIGSERIAL PRIMARY KEY,
    name        TEXT        NOT NULL UNIQUE,   -- "admin" | "manager" | "user" | "guest"
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- User ↔ Role assignments (many-to-many)
CREATE TABLE user_roles (
    user_id    BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role_id    BIGINT NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    granted_by BIGINT NOT NULL REFERENCES users(id),
    granted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, role_id)
);

-- Resources
CREATE TABLE resources (
    id         BIGSERIAL PRIMARY KEY,
    name       TEXT        NOT NULL UNIQUE,
    owner_id   BIGINT      NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Pre-populate the four canonical roles
INSERT INTO roles (name) VALUES ('admin'), ('manager'), ('user'), ('guest');
