-- examples/ledger/schema.sql
-- PostgreSQL schema for the Lyric enterprise ledger demo.
--
-- Apply with:
--   psql "$DATABASE_URL" -f examples/ledger/schema.sql
--
-- The schema enforces double-entry bookkeeping at the database level
-- (unique-per-transfer debit and credit entries) as a second safety layer
-- behind the Lyric @proof_required invariants.

CREATE TABLE IF NOT EXISTS accounts (
  id         BIGSERIAL    PRIMARY KEY,
  name       TEXT         NOT NULL,
  kind       TEXT         NOT NULL
               CHECK (kind IN ('asset','liability','equity','income','expense')),
  currency   TEXT         NOT NULL DEFAULT 'USD',
  created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS transfers (
  id         BIGSERIAL    PRIMARY KEY,
  from_id    BIGINT       NOT NULL REFERENCES accounts(id),
  to_id      BIGINT       NOT NULL REFERENCES accounts(id),
  -- Amounts stored as integer minor units (e.g. cents); avoids floating-point.
  amount     BIGINT       NOT NULL CHECK (amount > 0),
  note       TEXT         NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  CONSTRAINT no_self_transfer CHECK (from_id != to_id)
);

CREATE TABLE IF NOT EXISTS ledger_entries (
  id          BIGSERIAL    PRIMARY KEY,
  transfer_id BIGINT       NOT NULL REFERENCES transfers(id),
  account_id  BIGINT       NOT NULL REFERENCES accounts(id),
  amount      BIGINT       NOT NULL CHECK (amount > 0),
  side        TEXT         NOT NULL CHECK (side IN ('debit','credit')),
  created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- Database-level enforcement of double-entry: each transfer has exactly
-- one debit entry and one credit entry.  This is the DB-side mirror of
-- the @proof_required balancePreservation invariant in accounting.l.
CREATE UNIQUE INDEX IF NOT EXISTS uq_transfer_debit
  ON ledger_entries (transfer_id) WHERE side = 'debit';

CREATE UNIQUE INDEX IF NOT EXISTS uq_transfer_credit
  ON ledger_entries (transfer_id) WHERE side = 'credit';

-- Convenience view: net balance per account (credit minus debit).
-- A positive balance means net inflow; negative means net outflow.
-- For asset accounts, credits fund the account; debits draw it down.
CREATE OR REPLACE VIEW account_balances AS
SELECT
  a.id,
  a.name,
  a.kind,
  a.currency,
  COALESCE(
    SUM(CASE WHEN e.side = 'credit' THEN e.amount
                                    ELSE -e.amount END),
    0
  ) AS balance
FROM accounts a
LEFT JOIN ledger_entries e ON e.account_id = a.id
GROUP BY a.id, a.name, a.kind, a.currency;
