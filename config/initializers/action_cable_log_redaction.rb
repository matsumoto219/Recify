require Rails.root.join("lib/recify/action_cable_log_redactor").to_s

action_cable_logger = Rails.application.config.action_cable.logger || Rails.logger
unless action_cable_logger.is_a?(Recify::ActionCableLogger)
  Rails.application.config.action_cable.logger = Recify::ActionCableLogger.new(action_cable_logger)
end
