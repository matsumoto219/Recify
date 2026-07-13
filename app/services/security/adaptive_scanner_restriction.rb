# frozen_string_literal: true

require "digest"
require "securerandom"

module Security
  class AdaptiveScannerRestriction
    ACTIVATION_STRIKE_COUNT = 3
    STRIKE_RETENTION = 90.days
    PROBE_DEDUP_WINDOW = 1.second
    RESET_VERIFICATION_TTL = 30.seconds
    DURATIONS = [ 30.minutes, 6.hours, 24.hours, 7.days, 30.days ].freeze
    CACHE_NAMESPACE = "security:adaptive_scanner:v1"

    class << self
      def record_probe(ip_address:)
        new(ip_address: ip_address).record_probe
      end

      def snapshot(ip_address:)
        new(ip_address: ip_address).snapshot
      end

      def active?(ip_address:)
        snapshot(ip_address: ip_address).fetch(:active)
      end

      def reset!(ip_address:)
        new(ip_address: ip_address).reset!
      end
    end

    def initialize(ip_address:)
      @ip_address = IpAddress.normalize(ip_address)
    end

    def record_probe
      return empty_snapshot unless blockable?

      current = snapshot
      return current if current.fetch(:active)
      return current unless acquire_probe_gate

      strike_count = increment_strike_count
      return empty_snapshot(strike_count: strike_count) if strike_count < ACTIVATION_STRIKE_COUNT

      activate(strike_count)
    rescue StandardError => e
      log_cache_failure("record", e)
      empty_snapshot
    end

    def snapshot
      return empty_snapshot unless blockable?

      payload = cache.read(active_key)
      return empty_snapshot unless payload.respond_to?(:to_h)

      normalized = payload.to_h.with_indifferent_access
      return discard_invalid_active_payload unless valid_active_payload?(normalized)

      expires_at = Time.zone.at(normalized.fetch(:expires_at_epoch).to_i)
      if expires_at <= Time.current
        cache.delete(active_key)
        return empty_snapshot
      end

      {
        active: true,
        tier: normalized.fetch(:tier).to_i,
        strike_count: normalized.fetch(:strike_count).to_i,
        duration_seconds: normalized.fetch(:duration_seconds).to_i,
        expires_at: expires_at
      }
    rescue StandardError => e
      log_cache_failure("snapshot", e)
      empty_snapshot
    end

    def reset!
      return false if ip_address.blank?

      verification_token = SecureRandom.hex(16)
      cache.delete_multi(reset_keys)
      return false unless cache.write(
        reset_verification_key,
        verification_token,
        expires_in: RESET_VERIFICATION_TTL
      )

      reset_verified?(verification_token)
    rescue StandardError => e
      log_cache_failure("reset", e)
      false
    ensure
      delete_reset_verification_key
    end

    private

    attr_reader :ip_address

    def cache
      Rack::Attack.cache.store
    end

    def blockable?
      IpAddress.blockable?(ip_address)
    end

    def acquire_probe_gate
      cache.write(probe_gate_key, true, expires_in: PROBE_DEDUP_WINDOW, unless_exist: true)
    end

    def increment_strike_count
      cache.increment(strike_key, 1, expires_in: STRIKE_RETENTION).to_i
    end

    def activate(strike_count)
      tier = next_tier
      duration = DURATIONS.fetch(tier - 1)
      expires_at = Time.current + duration
      payload = {
        tier: tier,
        strike_count: strike_count,
        duration_seconds: duration.to_i,
        expires_at_epoch: expires_at.to_i
      }
      active_written = cache.write(active_key, payload, expires_in: duration)
      return failed_activation_snapshot(strike_count) unless active_written

      record_tier(tier)

      {
        active: true,
        tier: tier,
        strike_count: strike_count,
        duration_seconds: duration.to_i,
        expires_at: expires_at
      }
    end

    def next_tier
      previous_tier = cache.read(tier_key).to_i
      [ previous_tier + 1, DURATIONS.length ].min
    end

    def failed_activation_snapshot(strike_count)
      log_cache_rejection("activate")
      rolled_back_count = rollback_strike_increment
      empty_snapshot(strike_count: rolled_back_count || strike_count)
    end

    def rollback_strike_increment
      rolled_back_count = cache.decrement(strike_key, 1, expires_in: STRIKE_RETENTION)
      return rolled_back_count.to_i if rolled_back_count.is_a?(Numeric)

      deleted = cache.delete(strike_key)
      return 0 if deleted == true || (deleted.is_a?(Numeric) && deleted.positive?)

      nil
    rescue StandardError => e
      log_cache_failure("strike_rollback", e)
      nil
    end

    def record_tier(tier)
      written = cache.write(tier_key, tier, expires_in: STRIKE_RETENTION)
      log_cache_rejection("tier_history") unless written
    rescue StandardError => e
      log_cache_failure("tier_history", e)
    end

    def empty_snapshot(strike_count: 0)
      {
        active: false,
        tier: 0,
        strike_count: strike_count.to_i,
        duration_seconds: 0,
        expires_at: nil
      }
    end

    def valid_active_payload?(payload)
      %i[tier strike_count duration_seconds expires_at_epoch].all? { |key| payload.key?(key) }
    end

    def discard_invalid_active_payload
      cache.delete(active_key)
      empty_snapshot
    end

    def cache_key(kind)
      digest = Digest::SHA256.hexdigest(ip_address.to_s)
      "#{CACHE_NAMESPACE}:#{kind}:#{digest}"
    end

    def active_key
      cache_key("active")
    end

    def strike_key
      cache_key("strikes")
    end

    def probe_gate_key
      cache_key("probe_gate")
    end

    def tier_key
      cache_key("tier")
    end

    def reset_verification_key
      cache_key("reset_verification")
    end

    def reset_keys
      [ active_key, strike_key, probe_gate_key, tier_key ]
    end

    def reset_verified?(verification_token)
      values = cache.read_multi(reset_verification_key, *reset_keys)
      values[reset_verification_key] == verification_token && reset_keys.none? { |key| values.key?(key) }
    end

    def delete_reset_verification_key
      return if ip_address.blank?

      cache.delete(reset_verification_key)
    rescue StandardError => e
      log_cache_failure("reset_verification_cleanup", e)
    end

    def log_cache_rejection(operation)
      Rails.logger.warn(
        "[Security::AdaptiveScannerRestriction] cache_write_rejected operation=#{operation}"
      )
    end

    def log_cache_failure(operation, error)
      Rails.logger.warn(
        "[Security::AdaptiveScannerRestriction] cache_failure operation=#{operation} class=#{error.class.name}"
      )
    end
  end
end
