# frozen_string_literal: true

require "rails_helper"

RSpec.describe GaugeMetrics do
  describe ".gauge_sql?" do
    it "detects AVG" do
      expect(described_class.gauge_sql?("SELECT AVG(duration_nano) FROM t")).to eq(true)
      expect(described_class.gauge_sql?("SELECT COUNT(*) FROM t")).to eq(false)
    end
  end
end
