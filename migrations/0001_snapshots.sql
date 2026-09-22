CREATE TABLE IF NOT EXISTS published_datasets (
  kind TEXT PRIMARY KEY,
  source_at TEXT NOT NULL,
  received_at TEXT NOT NULL,
  digest TEXT NOT NULL,
  payload TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS dataset_snapshots (
  kind TEXT NOT NULL,
  digest TEXT NOT NULL,
  source_day TEXT NOT NULL,
  source_at TEXT NOT NULL,
  received_at TEXT NOT NULL,
  payload TEXT NOT NULL,
  PRIMARY KEY(kind, digest),
  UNIQUE(kind, source_day)
);
CREATE INDEX IF NOT EXISTS snapshots_source ON dataset_snapshots(kind, source_at);
