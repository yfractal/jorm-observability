CREATE TABLE IF NOT EXISTS trace_to_metrics (
  "name" STRING,
  "span_name" STRING,
  "metric_type" STRING,
  "dimensions" STRING,
  "filters" STRING,
  "bucket_interval" STRING,
  "backfill_through_timestamp" TIMESTAMP,
  "backfill_through_trace_id" STRING,
  "backfill_through_span_id" STRING,
  "backfill_finished_at" TIMESTAMP,
  "version" INT,
  "greptime_ts" TIMESTAMP DEFAULT CURRENT_TIMESTAMP() TIME INDEX,
  PRIMARY KEY ("name")
) WITH ('merge_mode'='last_row');
