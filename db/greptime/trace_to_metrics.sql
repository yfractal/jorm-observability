CREATE TABLE IF NOT EXISTS trace_to_metrics (
  "name" STRING,
  "span_name" STRING,
  "metric_type" STRING,
  "dimensions" STRING,
  "version" INT,
  "greptime_ts" TIMESTAMP DEFAULT CURRENT_TIMESTAMP() TIME INDEX,
  PRIMARY KEY ("name")
) WITH ('merge_mode'='last_row');
