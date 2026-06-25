# frozen_string_literal: true

module Middleware
  class SuppressStrictTransportSecurityHeader
    HEADER = "Strict-Transport-Security"

    def initialize(app)
      @app = app
    end

    def call(env)
      status, headers, response = @app.call(env)
      headers.delete(HEADER)
      [ status, headers, response ]
    end
  end
end
