# frozen_string_literal: true

module Security
  class RackAttackBanRegistry
    TARGETS = {
      "scanner" => {
        label: "scanner",
        filter: Rack::Attack::Fail2Ban,
        discriminator_prefix: "scanner",
        findtime: 10.minutes
      },
      "admin_probe" => {
        label: "admin_probe",
        filter: Rack::Attack::Allow2Ban,
        discriminator_prefix: "admin_probe",
        findtime: Rack::Attack::ADMIN_PROBE_FINDTIME
      },
      "direct_upload_probe" => {
        label: "direct_upload_probe",
        filter: Rack::Attack::Fail2Ban,
        discriminator_prefix: "direct_upload_probe",
        findtime: 10.minutes
      }
    }.freeze
    TARGET_NAMES = TARGETS.keys.freeze
    RESET_TARGETS = (TARGET_NAMES + [ "all" ]).freeze

    class << self
      def target_names
        TARGET_NAMES
      end

      def reset_targets
        RESET_TARGETS
      end

      def banned_states(ip_address)
        normalized = IpAddress.normalize(ip_address)
        return empty_states if normalized.blank?

        TARGETS.transform_values do |config|
          config.fetch(:filter).banned?(discriminator(config, normalized))
        end
      end

      def reset!(ip_address:, target:)
        normalized = IpAddress.normalize(ip_address)
        raise ValidationError, "invalid_ip" if normalized.blank?

        expanded_targets(target).each do |target_name|
          config = TARGETS.fetch(target_name)
          config.fetch(:filter).reset(
            discriminator(config, normalized),
            findtime: config.fetch(:findtime)
          )
        end
      end

      def expanded_targets(target)
        normalized = target.to_s
        raise ValidationError, "rack_attack_target_invalid" unless RESET_TARGETS.include?(normalized)

        normalized == "all" ? TARGET_NAMES : [ normalized ]
      end

      private

      def discriminator(config, ip_address)
        "#{config.fetch(:discriminator_prefix)}:#{ip_address}"
      end

      def empty_states
        TARGETS.transform_values { false }
      end
    end
  end
end
