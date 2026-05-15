-- examples/jobqueue/schema.sql
-- Background job queue schema for PostgreSQL.
--
-- Apply:  psql -d jobqueue -f examples/jobqueue/schema.sql

CREATE TYPE job_status AS ENUM ('pending', 'running', 'completed', 'failed');

CREATE TABLE jobs (
    id           BIGSERIAL    PRIMARY KEY,
    kind         TEXT         NOT NULL,
    payload      JSONB        NOT NULL DEFAULT '{}',
    status       job_status   NOT NULL DEFAULT 'pending',
    retry_count  INT          NOT NULL DEFAULT 0
                              CHECK (retry_count BETWEEN 0 AND 10),
    max_retries  INT          NOT NULL DEFAULT 3
                              CHECK (max_retries BETWEEN 0 AND 10),
    worker_id    TEXT         NOT NULL DEFAULT '',
    error        TEXT         NOT NULL DEFAULT '',
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT now(),
    claimed_at   TIMESTAMPTZ,
    completed_at TIMESTAMPTZ
);

-- Partial index: only pending jobs participate in the claim scan.
-- Keeps the index small as completed/failed rows accumulate.
CREATE INDEX jobs_claim_idx ON jobs (created_at ASC)
  WHERE status = 'pending';

-- Prevent retried jobs from exceeding their budget (belt-and-suspenders
-- alongside the Lyric @proof_required retryAllowed oracle).
ALTER TABLE jobs ADD CONSTRAINT jobs_retry_budget
  CHECK (retry_count <= max_retries);
