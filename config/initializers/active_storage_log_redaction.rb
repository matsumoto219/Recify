require Rails.root.join("lib/recify/active_storage_log_redactor").to_s
require "action_controller/log_subscriber"
require "action_dispatch/log_subscriber"
require "active_storage/log_subscriber"

module Recify
  module ActiveStorageLogRedaction
    module RackLogger
      private

      def started_request_message(request)
        ActiveStorageLogRedactor.redact(super)
      end
    end

    module ActionControllerLogSubscriber
      def redirect_to(event)
        info { "Redirected to #{ActiveStorageLogRedactor.redact(event.payload[:location])}" }
      end
    end

    module ActionDispatchLogSubscriber
      def redirect(event)
        info { "Redirected to #{ActiveStorageLogRedactor.redact(event.payload[:location])}" }
      end
    end

    module ActiveStorageLogSubscriber
      def service_url(event)
        debug event, color(
          "Generated URL for file at key: #{ActiveStorageLogRedactor::FILTERED_KEY} " \
            "(#{ActiveStorageLogRedactor.redact(event.payload[:url])})",
          ActiveStorage::LogSubscriber::BLUE
        )
      end
    end
  end
end

Rails.application.config.to_prepare do
  unless Rails::Rack::Logger < Recify::ActiveStorageLogRedaction::RackLogger
    Rails::Rack::Logger.prepend(Recify::ActiveStorageLogRedaction::RackLogger)
  end

  unless ActionController::LogSubscriber < Recify::ActiveStorageLogRedaction::ActionControllerLogSubscriber
    ActionController::LogSubscriber.prepend(Recify::ActiveStorageLogRedaction::ActionControllerLogSubscriber)
  end

  unless ActionDispatch::LogSubscriber < Recify::ActiveStorageLogRedaction::ActionDispatchLogSubscriber
    ActionDispatch::LogSubscriber.prepend(Recify::ActiveStorageLogRedaction::ActionDispatchLogSubscriber)
  end

  unless ActiveStorage::LogSubscriber < Recify::ActiveStorageLogRedaction::ActiveStorageLogSubscriber
    ActiveStorage::LogSubscriber.prepend(Recify::ActiveStorageLogRedaction::ActiveStorageLogSubscriber)
  end
end
