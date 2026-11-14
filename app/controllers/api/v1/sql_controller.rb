module Api
  module V1
    class SqlController < ActionController::API
      def create
        result = SqlQuery::Execute.call(sql_param)

        render json: {
          data: result.rows,
          sql: result.sql,
          used_metric: result.used_metric,
          metric_name: result.metric_name
        }, status: :ok
      rescue SqlQuery::ReadOnly::Error => e
        render json: { error: e.message }, status: :unprocessable_content
      rescue ActiveRecord::StatementInvalid => e
        render json: { error: e.message }, status: :bad_request
      end

      private

      def sql_param
        raw = params[:sql]
        raw = raw.to_s if raw
        raw
      end
    end
  end
end
