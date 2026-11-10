# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_09_231610) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "trace_to_metrics", force: :cascade do |t|
    t.string "name", null: false
    t.string "span_name", null: false
    t.string "metric_type", default: "counter", null: false
    t.jsonb "dimensions", default: [], null: false
    t.integer "version", default: 1, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_trace_to_metrics_on_name", unique: true
    t.index ["span_name"], name: "index_trace_to_metrics_on_span_name"
  end

  create_table "traces", force: :cascade do |t|
    t.timestamptz "timestamp", null: false
    t.timestamptz "timestamp_end"
    t.bigint "duration_nano"
    t.string "parent_span_id"
    t.string "trace_id"
    t.string "span_id"
    t.string "span_kind"
    t.string "span_name"
    t.string "span_status_code"
    t.string "span_status_message"
    t.string "trace_state"
    t.string "scope_name"
    t.string "scope_version"
    t.string "service_name"
    t.jsonb "span_attributes", default: {}, null: false
    t.jsonb "resource_attributes", default: {}, null: false
    t.jsonb "span_events", default: [], null: false
    t.jsonb "span_links", default: [], null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["resource_attributes"], name: "index_traces_on_resource_attributes", using: :gin
    t.index ["span_attributes"], name: "index_traces_on_span_attributes", using: :gin
    t.index ["span_name"], name: "index_traces_on_span_name"
    t.index ["timestamp"], name: "index_traces_on_timestamp"
    t.index ["trace_id"], name: "index_traces_on_trace_id"
  end
end
