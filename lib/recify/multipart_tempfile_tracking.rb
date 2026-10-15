require "rack/multipart"

module Recify
  class MultipartTempfileTracking
    def initialize(app)
      @app = app
    end

    def call(env)
      if Rack::MediaType.type(env["CONTENT_TYPE"]) == "multipart/form-data"
        factory = env[Rack::RACK_MULTIPART_TEMPFILE_FACTORY] || Rack::Multipart::Parser::TEMPFILE_FACTORY
        env[Rack::RACK_MULTIPART_TEMPFILE_FACTORY] = lambda do |*arguments|
          factory.call(*arguments).tap do |file|
            # Rack normally registers these only after parsing succeeds.
            env.fetch(Rack::RACK_TEMPFILES) << file
          end
        end
      end

      @app.call(env)
    end
  end
end
