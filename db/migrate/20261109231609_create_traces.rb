class CreateTraces < ActiveRecord::Migration[8.1]
  def change
    create_table :traces do |t|
      t.timestamptz :timestamp, null: false
      t.timestamptz :timestamp_end
      t.bigint :duration_nano
      t.string :parent_span_id
      t.string :trace_id
      t.string :span_id
      t.string :span_kind
      t.string :span_name
      t.string :span_status_code
      t.string :span_status_message
      t.string :trace_state
      t.string :scope_name
      t.string :scope_version
      t.string :service_name
      t.jsonb :span_attributes, null: false, default: {}
      t.jsonb :resource_attributes, null: false, default: {}
      t.jsonb :span_events, null: false, default: []
      t.jsonb :span_links, null: false, default: []

      t.timestamps
    end

    add_index :traces, :trace_id
    add_index :traces, :span_name
    add_index :traces, :timestamp
    add_index :traces, :span_attributes, using: :gin
    add_index :traces, :resource_attributes, using: :gin
  end
end
