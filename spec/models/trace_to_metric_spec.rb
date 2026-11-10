require "rails_helper"

RSpec.describe TraceToMetric, type: :model do
  describe "validations and naming" do
    it "derives name from span_name and metric_type" do
      definition = described_class.new(
        span_name: "http",
        metric_type: "counter",
        dimensions: [ "http.method" ]
      )

      expect(definition).to be_valid
      expect(definition.name).to eq("http_counter")
    end

    it "rejects names that do not match the convention" do
      definition = described_class.new(
        name: "wrong_name",
        span_name: "http",
        metric_type: "counter"
      )

      expect(definition).not_to be_valid
      expect(definition.errors[:name]).to include("must be http_counter")
    end

    it "rejects reserved table names" do
      definition = described_class.new(
        name: "traces",
        span_name: "traces",
        metric_type: "counter"
      )

      # name would derive to traces_counter; force reserved
      definition.name = "traces"
      expect(definition).not_to be_valid
      expect(definition.errors[:name]).to include("is reserved")
    end

    it "rejects removing dimensions on update", :no_transaction do
      definition = described_class.create!(
        span_name: "http",
        metric_type: "counter",
        dimensions: [ "a", "b" ]
      )

      definition.dimensions = [ "a" ]
      expect(definition).not_to be_valid
      expect(definition.errors[:dimensions]).to include("can only be added, not removed or renamed")
    end
  end

  describe "metric table lifecycle", :no_transaction do
    it "creates the metric table after create" do
      definition = described_class.create!(
        span_name: "http",
        metric_type: "counter",
        dimensions: [ "http.method", "http.route" ]
      )

      expect(Greptime::Connection.table_exists?("http_counter")).to eq(true)
      columns = Greptime::Connection.column_names("http_counter")
      expect(columns).to include("bucket", "http_method", "http_route", "value")
      expect(definition.version.to_i).to eq(1)
    end

    it "adds new dimensions and bumps version on update" do
      definition = described_class.create!(
        span_name: "redis",
        metric_type: "counter",
        dimensions: [ "db.system" ]
      )

      definition.update!(dimensions: [ "db.system", "net.peer.name" ])
      definition.reload

      columns = Greptime::Connection.column_names("redis_counter")
      expect(columns).to include("db_system", "net_peer_name")
      expect(definition.version.to_i).to eq(2)
    end
  end

  describe ".for_span_name" do
    it "finds the definition by span_name", :no_transaction do
      definition = described_class.create!(
        span_name: "http",
        metric_type: "counter",
        dimensions: []
      )

      expect(described_class.for_span_name("http").name).to eq(definition.name)
      expect(described_class.for_span_name("missing")).to be_nil
    end
  end
end
