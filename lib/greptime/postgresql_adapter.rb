module Greptime
  module PostgreSQLAdapter
    # Fake a modern Postgres server version for GreptimeDB connections.
    GREPTIME_PG_VERSION = 16_00_00

    def greptimedb?
      hash =
        if respond_to?(:connection_db_config) && connection_db_config
          connection_db_config.configuration_hash
        elsif defined?(@config) && @config
          @config
        else
          {}
        end
      hash = hash.symbolize_keys if hash.respond_to?(:symbolize_keys)
      hash[:greptimedb] == true
    end

    def supports_insert_returning?
      return false if greptimedb?

      super
    end

    def supports_identity_columns?
      return false if greptimedb?

      super
    end

    def supports_deferred_unique_constraints?
      return false if greptimedb?

      super
    end

    def get_database_version # :nodoc:
      return GREPTIME_PG_VERSION if greptimedb?

      super
    end

    # GreptimeDB does not support SHOW max_identifier_length.
    def max_identifier_length # :nodoc:
      return 63 if greptimedb?

      super
    end

    # GreptimeDB does not implement pg_catalog index helpers used by AR.
    def indexes(_table_name) # :nodoc:
      return [] if greptimedb?

      super
    end

    def reset!
      return super unless greptimedb?

      @lock.synchronize do
        return connect! unless @raw_connection

        unless @raw_connection.transaction_status == ::PG::PQTRANS_IDLE
          begin
            @raw_connection.query "ROLLBACK"
          rescue ::PG::Error
            nil
          end
        end

        # GreptimeDB does not support DISCARD ALL; skip session reset.
        clear_cache!(new_connection: true)
        configure_connection
      end
    end
  end
end



ActiveSupport.on_load(:active_record_postgresqladapter) do
  prepend Greptime::PostgreSQLAdapter
end
