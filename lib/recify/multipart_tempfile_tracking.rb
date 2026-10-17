require "delegate"
require "rack/multipart"

module Recify
  class MultipartTempfileTracking
    class AnonymousTempfile < SimpleDelegator
      def initialize
        file = Tempfile.create("RackMultipart", anonymous: true)
        file.binmode
        raise IOError, "anonymous multipart tempfile unavailable" unless file.stat.nlink.zero?

        super(file)
      rescue StandardError
        file&.close
        raise
      end

      def open
        rewind
        __getobj__
      end

      def close(_unlink_now = false)
        __getobj__.close
      end

      alias_method :close!, :close
    end
    private_constant :AnonymousTempfile

    def initialize(app)
      @app = app
    end

    def call(env)
      if Rack::MediaType.type(env["CONTENT_TYPE"]) == "multipart/form-data"
        factory = env[Rack::RACK_MULTIPART_TEMPFILE_FACTORY] || ->(*) { AnonymousTempfile.new }
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
