# frozen_string_literal: true

require "rails_helper"

RSpec.describe CounterMetrics do
  describe ".counter_sql?" do
    it "detects COUNT" do
      expect(described_class.counter_sql?("SELECT COUNT(*) FROM t")).to eq(true)
      expect(described_class.counter_sql?("SELECT AVG(duration_nano) FROM t")).to eq(false)
    end
  end
end
