# frozen_string_literal: true

module Security
  class RackAttackBanRegistry
    LEGACY_SCANNER_COMPATIBILITY_WINDOW = 30.minutes
    LEGACY_SCANNER_COMPATIBILITY_DEADLINE =
      Process.clock_gettime(Process::CLOCK_MONOTONIC) + LEGACY_SCANNER_COMPATIBILITY_WINDOW.to_f
    TARGETS = {
      "scanner" => {
        label: "scanner",
        adaptive: true,
        legacy_filter: Rack::Attack::Fail2Ban,
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

      def legacy_scanner_banned?(ip_address)
        return false unless legacy_scanner_compatibility_active?

        normalized = IpAddress.normalize(ip_address)
        return false if normalized.blank?

        config = TARGETS.fetch("scanner")
        config.fetch(:legacy_filter).banned?(discriminator(config, normalized))
      end

      def banned_states(ip_address)
        normalized = IpAddress.normalize(ip_address)
        return empty_states if normalized.blank?

        TARGETS.transform_values do |config|
          banned_state(config, normalized)
        end
      end

      def reset!(ip_address:, target:)
        normalized = IpAddress.normalize(ip_address)
        raise ValidationError, "invalid_ip" if normalized.blank?

        expanded_targets(target).each do |target_name|
          config = TARGETS.fetch(target_name)
          reset_target(config, normalized)
        end
      end

      def expanded_targets(target)
        normalized = target.to_s
        raise ValidationError, "rack_attack_target_invalid" unless RESET_TARGETS.include?(normalized)

        normalized == "all" ? TARGET_NAMES : [ normalized ]
      end

      private

      def legacy_scanner_compatibility_active?
        Process.clock_gettime(Process::CLOCK_MONOTONIC) < LEGACY_SCANNER_COMPATIBILITY_DEADLINE
      end

      def banned_state(config, ip_address)
        if config[:adaptive]
          return AdaptiveScannerRestriction.active?(ip_address: ip_address) ||
            legacy_scanner_banned?(ip_address)
        end

        config.fetch(:filter).banned?(discriminator(config, ip_address))
      end

      def reset_target(config, ip_address)
        if config[:adaptive]
          AdaptiveScannerRestriction.reset!(ip_address: ip_address)
          config.fetch(:legacy_filter).reset(
            discriminator(config, ip_address),
            findtime: config.fetch(:findtime)
          )
        else
          config.fetch(:filter).reset(
            discriminator(config, ip_address),
            findtime: config.fetch(:findtime)
          )
        end
      end

      def discriminator(config, ip_address)
        "#{config.fetch(:discriminator_prefix)}:#{ip_address}"
      end

      def empty_states
        TARGETS.transform_values { false }
      end
    end
  end
end
