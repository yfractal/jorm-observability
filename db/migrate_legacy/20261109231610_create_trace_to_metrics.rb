class CreateTraceToMetrics < ActiveRecord::Migration[8.1]
  def change
    create_table :trace_to_metrics do |t|
      t.string :name, null: false
      t.string :span_name, null: false
      t.string :metric_type, null: false, default: "counter"
      t.jsonb :dimensions, null: false, default: []
      t.integer :version, null: false, default: 1

      t.timestamps
    end

    add_index :trace_to_metrics, :name, unique: true
    add_index :trace_to_metrics, :span_name
  end
end
