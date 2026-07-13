# frozen_string_literal: true

module Security
  Error = Class.new(StandardError)
  ValidationError = Class.new(Error)

  class << self
    def ip_access_snapshot(...)
      IpAccessSnapshot.call(...)
    end

    def request_ip_snapshot(...)
      RequestIpSnapshot.call(...)
    end

    def normalize_ip_address(value)
      IpAddress.normalize(value)
    end

    def ip_address_blockable?(value)
      IpAddress.blockable?(value)
    end

    def ip_address_non_blockable_reason(value)
      IpAddress.non_blockable_reason(value)
    end

    def rack_attack_banned_states(ip_address)
      RackAttackBanRegistry.banned_states(ip_address)
    end

    def scanner_restriction_snapshot(ip_address)
      snapshot = AdaptiveScannerRestriction.snapshot(ip_address: ip_address)
      return snapshot if snapshot.fetch(:active)
      return snapshot unless RackAttackBanRegistry.legacy_scanner_banned?(ip_address)

      snapshot.merge(
        active: true,
        tier: 1,
        duration_seconds: 30.minutes.to_i,
        expires_at: 30.minutes.from_now
      )
    end

    def record_scanner_probe(ip_address)
      AdaptiveScannerRestriction.record_probe(ip_address: ip_address)
    end

    def rack_attack_default_target
      RackAttackBanResetter::DEFAULT_TARGET
    end

    def ip_blocked?(ip_address)
      IpAccessRules.blocked?(ip_address)
    end

    def manual_ip_block(...)
      ManualIpBlocker.call(...)
    end

    def manual_ip_unblock(...)
      ManualIpUnblocker.call(...)
    end

    def rack_attack_ban_reset(...)
      RackAttackBanResetter.call(...)
    end

    def record_ip_action(...)
      IpActionRecorder.call(...)
    end

    def record_ip_rate_limit_action(...)
      IpActionRecorder.record_rate_limit(...)
    end

    def record_ip_access_operation(...)
      IpActionRecorder.record_operation(...)
    end
  end
end
