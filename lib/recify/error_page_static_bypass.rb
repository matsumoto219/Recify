module Recify
  class ErrorPageStaticBypass
    ERROR_ROUTES = {
      "/404" => "/errors/not_found",
      "/422" => "/errors/unprocessable",
      "/500" => "/errors/internal_server_error"
    }.freeze

    def initialize(app)
      @app = app
    end

    def call(env)
      target_path = ERROR_ROUTES[env["PATH_INFO"]]

      if target_path && %w[GET HEAD].include?(env["REQUEST_METHOD"])
        env = env.dup
        env["action_dispatch.original_fullpath"] ||= env["PATH_INFO"]
        env["PATH_INFO"] = target_path
      end

      @app.call(env)
    end
  end
end
