class CreateSpanToMetrics < ActiveRecord::Migration[8.1]
  def change
    create_table :span_to_metrics do |t|
      t.string :name, null: false
      t.string :span_name, null: false
      t.string :metric_type, null: false, default: "counter"
      t.jsonb :dimensions, null: false, default: []
      t.integer :version, null: false, default: 1

      t.timestamps
    end

    add_index :span_to_metrics, :name, unique: true
    add_index :span_to_metrics, :span_name
  end
end
