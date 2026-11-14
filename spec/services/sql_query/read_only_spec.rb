require "rails_helper"

RSpec.describe SqlQuery::ReadOnly do
  describe ".validate!" do
    it "accepts a plain SELECT" do
      expect(described_class.validate!("SELECT 1")).to eq("SELECT 1")
    end

    it "accepts a read-only WITH ... SELECT" do
      sql = "WITH a AS (SELECT 1 AS x) SELECT * FROM a"
      expect(described_class.validate!(sql)).to eq(sql)
    end

    it "rejects blank sql" do
      expect {
        described_class.validate!("")
      }.to raise_error(SqlQuery::ReadOnly::Error, /required/)
    end

    it "rejects INSERT" do
      expect {
        described_class.validate!("INSERT INTO opentelemetry_traces (trace_id) VALUES ('x')")
      }.to raise_error(SqlQuery::ReadOnly::Error, /only SELECT/)
    end

    it "rejects multiple statements" do
      expect {
        described_class.validate!("SELECT 1; SELECT 2")
      }.to raise_error(SqlQuery::ReadOnly::Error, /single statement/)
    end

    it "rejects SELECT INTO" do
      expect {
        described_class.validate!("SELECT * INTO tmp FROM opentelemetry_traces")
      }.to raise_error(SqlQuery::ReadOnly::Error, /SELECT INTO/)
    end

    it "rejects data-modifying CTEs" do
      sql = "WITH a AS (INSERT INTO opentelemetry_traces (trace_id) VALUES ('x') RETURNING *) SELECT * FROM a"
      expect {
        described_class.validate!(sql)
      }.to raise_error(SqlQuery::ReadOnly::Error, /read-only WITH/)
    end
  end
end
