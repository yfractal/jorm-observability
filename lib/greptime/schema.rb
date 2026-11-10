module Greptime
  module Schema
    SCHEMA_DIR = Rails.root.join("db/greptime")

    module_function

    def load!
      connection = ActiveRecord::Base.connection
      Dir[SCHEMA_DIR.join("*.sql")].sort.each do |path|
        sql = File.read(path)
        connection.execute(sql)
      end
    end
  end
end
