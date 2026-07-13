# frozen_string_literal: true

require "digest"

module Security
  class AdaptiveScannerRestriction
    ACTIVATION_STRIKE_COUNT = 3
    STRIKE_RETENTION = 90.days
    PROBE_DEDUP_WINDOW = 1.second
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

      cache.delete_multi([ active_key, strike_key, probe_gate_key ])
      true
    rescue StandardError => e
      log_cache_failure("reset", e)
      false
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
      tier = [ strike_count - ACTIVATION_STRIKE_COUNT + 1, DURATIONS.length ].min
      duration = DURATIONS.fetch(tier - 1)
      expires_at = Time.current + duration
      payload = {
        tier: tier,
        strike_count: strike_count,
        duration_seconds: duration.to_i,
        expires_at_epoch: expires_at.to_i
      }
      cache.write(active_key, payload, expires_in: duration)

      {
        active: true,
        tier: tier,
        strike_count: strike_count,
        duration_seconds: duration.to_i,
        expires_at: expires_at
      }
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

    def log_cache_failure(operation, error)
      Rails.logger.warn(
        "[Security::AdaptiveScannerRestriction] cache_failure operation=#{operation} class=#{error.class.name}"
      )
    end
  end
end
