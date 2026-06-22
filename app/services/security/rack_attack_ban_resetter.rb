# frozen_string_literal: true

module Security
  class RackAttackBanResetter
    DEFAULT_TARGET = "all"

    Result = Struct.new(
      :success,
      :ip_address,
      :target,
      :reset_targets,
      :before_state,
      :after_state,
      :error_code,
      keyword_init: true
    ) do
      def success?
        success == true
      end

      def failure?
        !success?
      end
    end

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(ip_address:, target: DEFAULT_TARGET)
      @ip_address = IpAddress.normalize(ip_address)
      @target = target.to_s.presence || DEFAULT_TARGET
    end

    def call
      validate!

      before_state = RackAttackBanRegistry.banned_states(ip_address)
      RackAttackBanRegistry.reset!(ip_address: ip_address, target: target)
      after_state = RackAttackBanRegistry.banned_states(ip_address)

      Result.new(
        success: true,
        ip_address: ip_address,
        target: target,
        reset_targets: reset_targets,
        before_state: before_state,
        after_state: after_state
      )
    rescue Security::ValidationError => e
      Result.new(success: false, ip_address: ip_address, target: target, reset_targets: [], error_code: e.message)
    end

    private

    attr_reader :ip_address, :target

    def validate!
      raise ValidationError, "invalid_ip" if ip_address.blank?
      raise ValidationError, "rack_attack_target_invalid" unless RackAttackBanRegistry.reset_targets.include?(target)
    end

    def reset_targets
      RackAttackBanRegistry.expanded_targets(target)
    end
  end
end
