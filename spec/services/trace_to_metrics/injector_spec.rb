require "rails_helper"

RSpec.describe TraceToMetrics::Injector, :no_transaction do
  def create_definition!(span_name: "http", dimensions: [ "http.request.method", "http.route" ])
    TraceToMetric.create!(
      span_name: span_name,
      metric_type: "counter",
      dimensions: dimensions
    )
  end

  def create_trace!(attrs = {})
    Trace.create!(
      {
        timestamp: Time.utc(2026, 11, 10, 8, 22, 15, 123_456),
        span_name: "http",
        trace_id: SecureRandom.hex(16),
        span_id: SecureRandom.hex(8),
        service_name: "lobsters",
        span_kind: "SERVER",
        span_status_code: "OK",
        span_attributes: {
          "http.request.method" => "GET",
          "http.route" => "/stories"
        },
        resource_attributes: {}
      }.merge(attrs)
    )
  end

  def rows_for(table)
    ActiveRecord::Base.connection.exec_query("SELECT * FROM #{table} ORDER BY id").to_a
  end

  after do
    conn = ActiveRecord::Base.connection
    %w[http_counter redis_counter bare_counter].each do |table|
      conn.drop_table(table, if_exists: true)
    end
  end

  it "creates a row with value 1 on first inject" do
    definition = create_definition!
    trace = create_trace!

    described_class.call(trace, definition)

    rows = rows_for("http_counter")
    expect(rows.size).to eq(1)
    expect(rows.first["value"]).to eq(1)
    expect(rows.first["http_request_method"]).to eq("GET")
    expect(rows.first["http_route"]).to eq("/stories")
    expect(rows.first["bucket"]).to eq(Time.utc(2026, 11, 10, 8, 22, 15))
  end

  it "increments the same row for traces in the same second with the same dimensions" do
    definition = create_definition!
    first = create_trace!(timestamp: Time.utc(2026, 11, 10, 8, 22, 15, 100_000))
    second = create_trace!(timestamp: Time.utc(2026, 11, 10, 8, 22, 15, 900_000))

    described_class.call(first, definition)
    described_class.call(second, definition)

    rows = rows_for("http_counter")
    expect(rows.size).to eq(1)
    expect(rows.first["value"]).to eq(2)
  end

  it "creates a separate row for a different dimension value" do
    definition = create_definition!
    get_trace = create_trace!
    post_trace = create_trace!(
      span_attributes: {
        "http.request.method" => "POST",
        "http.route" => "/stories"
      }
    )

    described_class.call(get_trace, definition)
    described_class.call(post_trace, definition)

    rows = rows_for("http_counter")
    expect(rows.size).to eq(2)
    expect(rows.map { |r| r["value"] }).to all(eq(1))
    expect(rows.map { |r| r["http_request_method"] }).to contain_exactly("GET", "POST")
  end

  it "creates a separate row for a different second" do
    definition = create_definition!
    first = create_trace!(timestamp: Time.utc(2026, 11, 10, 8, 22, 15))
    second = create_trace!(timestamp: Time.utc(2026, 11, 10, 8, 22, 16))

    described_class.call(first, definition)
    described_class.call(second, definition)

    rows = rows_for("http_counter")
    expect(rows.size).to eq(2)
    expect(rows.map { |r| r["value"] }).to all(eq(1))
  end

  it "stores missing attributes as empty string and aggregates them" do
    definition = create_definition!
    first = create_trace!(span_attributes: {})
    second = create_trace!(span_attributes: {})

    described_class.call(first, definition)
    described_class.call(second, definition)

    rows = rows_for("http_counter")
    expect(rows.size).to eq(1)
    expect(rows.first["value"]).to eq(2)
    expect(rows.first["http_request_method"]).to eq("")
    expect(rows.first["http_route"]).to eq("")
  end

  it "resolves dimensions from span attributes, resource attributes, then core columns" do
    definition = create_definition!(
      dimensions: [ "http.request.method", "deployment.environment", "service_name" ]
    )
    trace = create_trace!(
      span_attributes: { "http.request.method" => "GET" },
      resource_attributes: { "deployment.environment" => "production" },
      service_name: "lobsters"
    )

    described_class.call(trace, definition)

    row = rows_for("http_counter").first
    expect(row["http_request_method"]).to eq("GET")
    expect(row["deployment_environment"]).to eq("production")
    expect(row["service_name"]).to eq("lobsters")
  end

  it "aggregates by bucket only when there are no dimensions" do
    definition = TraceToMetric.create!(
      span_name: "bare",
      metric_type: "counter",
      dimensions: []
    )
    first = create_trace!(span_name: "bare")
    second = create_trace!(span_name: "bare")

    described_class.call(first, definition)
    described_class.call(second, definition)

    rows = rows_for("bare_counter")
    expect(rows.size).to eq(1)
    expect(rows.first["value"]).to eq(2)
  end

  it "atomically increments under concurrent injects" do
    definition = create_definition!
    base_time = Time.utc(2026, 11, 10, 8, 22, 15)
    thread_count = 8
    traces = thread_count.times.map { create_trace!(timestamp: base_time) }
    original_config = ActiveRecord::Base.connection_db_config.configuration_hash

    begin
      ActiveRecord::Base.connection_handler.clear_active_connections!(:all)
      ActiveRecord::Base.establish_connection(
        original_config.merge(max_connections: thread_count + 2, pool: nil)
      )

      threads = traces.map do |trace|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            described_class.call(trace, definition)
          end
        end
      end
      threads.each(&:join)
    ensure
      ActiveRecord::Base.connection_handler.clear_active_connections!(:all)
      ActiveRecord::Base.establish_connection(original_config)
    end

    rows = rows_for("http_counter")
    expect(rows.size).to eq(1)
    expect(rows.first["value"]).to eq(thread_count)
  end

  it "keeps aggregating after a new dimension is added" do
    definition = create_definition!(dimensions: [ "http.request.method" ])
    first = create_trace!
    described_class.call(first, definition)

    definition.update!(dimensions: [ "http.request.method", "http.route" ])

    second = create_trace!
    described_class.call(second, definition)

    rows = rows_for("http_counter")
    expect(rows.size).to eq(2)

    old_row = rows.find { |r| r["http_route"] == "" }
    new_row = rows.find { |r| r["http_route"] == "/stories" }

    expect(old_row["value"]).to eq(1)
    expect(old_row["http_request_method"]).to eq("GET")
    expect(new_row["value"]).to eq(1)
    expect(new_row["http_request_method"]).to eq("GET")
  end

  it "skips unsupported metric types with a warning" do
    definition = create_definition!
    definition.update_column(:metric_type, "gauge")
    trace = create_trace!

    expect(Rails.logger).to receive(:warn).with(/unsupported metric_type/)
    described_class.call(trace, definition)

    expect(rows_for("http_counter")).to be_empty
  end
end
