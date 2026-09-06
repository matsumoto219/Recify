module Recify
  class ErrorPageFallback
    def initialize(app, public_path:, logger: nil)
      @app = app
      @public_exceptions = ActionDispatch::PublicExceptions.new(public_path)
      @logger = logger
    end

    def call(env)
      @app.call(env)
    rescue StandardError => e
      log_failure(env, e)
      static_response(env)
    end

    private

    def static_response(env)
      fallback_env = env.merge("PATH_INFO" => "/500")
      status, headers, body = @public_exceptions.call(fallback_env)
      return plain_response(env) if headers["x-cascade"] == "pass"

      body = [] if head_request?(env)
      [ status, headers.merge("cache-control" => "no-store"), body ]
    rescue StandardError
      plain_response(env)
    end

    def plain_response(env)
      body = head_request?(env) ? [] : [ "500 Internal Server Error" ]
      [ 500, { "content-type" => "text/plain; charset=utf-8", "cache-control" => "no-store" }, body ]
    end

    def head_request?(env)
      (env["action_dispatch.original_request_method"] || env["REQUEST_METHOD"]) == "HEAD"
    end

    def log_failure(env, exception)
      request_id = env["action_dispatch.request_id"]
      request_id = nil unless request_id.is_a?(String) && request_id.bytesize <= 255 && request_id.ascii_only? && request_id.match?(/\A[A-Za-z0-9_-]+\z/)
      (@logger || Rails.logger).error(
        "[ErrorPageFallback] status=500 request_id=#{request_id || 'nil'} exception_class=#{exception.class.name}"
      )
    rescue StandardError
      nil
    end
  end
end
