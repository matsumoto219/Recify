# frozen_string_literal: true

require "digest"
require "securerandom"

module Security
  class AdaptiveScannerRestriction
    ACTIVATION_STRIKE_COUNT = 3
    STRIKE_RETENTION = 90.days
    PROBE_DEDUP_WINDOW = 1.second
    RESET_VERIFICATION_TTL = 30.seconds
    DURATIONS = [ 30.minutes, 6.hours, 24.hours, 7.days, 30.days, 90.days ].freeze
    DURABLE_STATE_MATCHED_RULE = "adaptive/scanner_state"
    CACHE_NAMESPACE = "security:adaptive_scanner:v1"
    DURABLE_STATE_ACTION_TYPE = "scanner_restriction"
    DURABLE_STATE_SOURCE = "rack_attack"
    DURABLE_STATE_STATUSES = %w[active revoked].freeze
    LEGACY_STATE_MATCHED_RULE = "fail2ban/scanner_paths"
    LEGACY_RESET_ACTION_TYPE = "rack_attack_ban_reset"
    LEGACY_RESET_MATCHED_RULE = "rack_attack/reset"

    ActivationError = Class.new(StandardError)
    private_constant :ActivationError,
      :DURABLE_STATE_ACTION_TYPE,
      :DURABLE_STATE_SOURCE,
      :DURABLE_STATE_STATUSES,
      :LEGACY_STATE_MATCHED_RULE,
      :LEGACY_RESET_ACTION_TYPE,
      :LEGACY_RESET_MATCHED_RULE

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

      record_probe_with_lock
    rescue StandardError => e
      log_cache_failure("record", e)
      empty_snapshot
    end

    def snapshot
      return empty_snapshot unless blockable?

      cached = cached_snapshot
      return cached if cached

      recover_durable_snapshot
    rescue StandardError => e
      log_state_failure("snapshot", e)
      empty_snapshot
    end

    def reset!
      return false if ip_address.blank?

      verification_token = SecureRandom.hex(16)
      reset_succeeded = IpAccessOperationLock.call(ip_address: ip_address) do
        record_durable_revocation!
        cache.delete_multi(progress_keys)
        raise ActivationError unless write_inactive_cache(verification_token: verification_token)
        raise ActivationError unless cache.write(
          reset_verification_key,
          verification_token,
          expires_in: RESET_VERIFICATION_TTL
        )
        raise ActivationError unless reset_verified?(verification_token)

        true
      end
      reset_succeeded == true
    rescue StandardError => e
      log_state_failure("reset", e)
      false
    ensure
      delete_reset_verification_key_if_token(verification_token)
      delete_inactive_cache_if_token(verification_token) unless reset_succeeded
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

    def record_probe_with_lock
      strike_count = nil
      state_token = nil
      IpAccessOperationLock.call(ip_address: ip_address) do
        current = active_snapshot_while_locked
        next current if current

        strike_count = increment_strike_count
        next empty_snapshot(strike_count: strike_count) if strike_count < ACTIVATION_STRIKE_COUNT

        state_token = SecureRandom.hex(16)
        activate_while_locked(strike_count, state_token: state_token)
      end
    rescue StandardError => e
      delete_active_cache_if_token(state_token)
      log_state_failure("record", e)
      return failed_activation_snapshot(strike_count) if state_token

      empty_snapshot
    end

    def activate(strike_count)
      state_token = SecureRandom.hex(16)
      activated = IpAccessOperationLock.call(ip_address: ip_address) do
        current = active_snapshot_while_locked
        next current if current

        activate_while_locked(strike_count, state_token: state_token)
      end
      activated
    rescue StandardError => e
      delete_active_cache_if_token(state_token)
      log_state_failure("activate", e)
      failed_activation_snapshot(strike_count)
    end

    def activate_while_locked(strike_count, state_token:)
      tier = next_tier(strike_count)
      duration = DURATIONS.fetch(tier - 1)
      expires_at = Time.current + duration
      strike_expires_at = strike_expiry_for_activation
      result = active_snapshot(
        tier: tier,
        strike_count: strike_count,
        duration_seconds: duration.to_i,
        expires_at: expires_at
      )

      record_durable_activation!(result, strike_expires_at: strike_expires_at)
      raise ActivationError unless write_active_cache(
        result,
        strike_expires_at: strike_expires_at,
        state_token: state_token
      )

      record_tier(tier, expires_at: strike_expires_at)
      result
    end

    def next_tier(strike_count)
      previous_tier = cache.read(tier_key).to_i
      strike_count_tier = strike_count - ACTIVATION_STRIKE_COUNT + 1

      [ previous_tier + 1, strike_count_tier, DURATIONS.length ].min.clamp(1, DURATIONS.length)
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

    def record_tier(tier, expires_at: STRIKE_RETENTION.from_now)
      remaining = expires_at - Time.current
      return unless remaining.positive?

      written = cache.write(tier_key, tier, expires_in: remaining)
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

    def active_snapshot(tier:, strike_count:, duration_seconds:, expires_at:)
      {
        active: true,
        tier: tier.to_i,
        strike_count: strike_count.to_i,
        duration_seconds: duration_seconds.to_i,
        expires_at: expires_at
      }
    end

    def cached_snapshot(migrate_legacy: true, restore_progress: false)
      payload = cache.read(active_key)
      return unless payload.respond_to?(:to_h)

      normalized = payload.to_h.with_indifferent_access
      if normalized[:active] == false
        if normalized[:durable_progress] == true && restore_progress
          restore_progress_cache_from_metadata(normalized)
        end
        return empty_snapshot
      end
      return discard_invalid_active_payload unless valid_active_payload?(normalized)

      expires_at = Time.zone.at(normalized.fetch(:expires_at_epoch).to_i)
      return discard_expired_active_payload if expires_at <= Time.current

      result = active_snapshot(
        tier: normalized.fetch(:tier),
        strike_count: normalized.fetch(:strike_count),
        duration_seconds: normalized.fetch(:duration_seconds),
        expires_at: expires_at
      )
      return result if normalized[:durable] == true
      return result unless migrate_legacy

      migrate_legacy_cached_snapshot(result)
    end

    def recover_durable_snapshot
      IpAccessOperationLock.call(ip_address: ip_address) do
        cached = cached_snapshot(migrate_legacy: false, restore_progress: true)
        return cached if cached

        state = latest_durable_state
        unless state
          if legacy_scanner_reset_barrier?
            record_durable_revocation!
            write_inactive_cache
            next empty_snapshot
          end

          legacy = legacy_active_snapshot
          if legacy
            strike_expires_at = inferred_strike_expires_at(legacy)
            record_durable_activation!(legacy, strike_expires_at: strike_expires_at)
            write_legacy_active_cache(legacy)
            next legacy
          end
        end

        restore_progress_cache(state)
        durable = durable_active_snapshot(state)
        unless durable
          write_inactive_cache(state: state)
          next empty_snapshot
        end

        strike_expires_at = durable_strike_expires_at(state)
        written = write_active_cache(
          durable,
          strike_expires_at: strike_expires_at,
          state_token: SecureRandom.hex(16)
        )
        unless written
          log_cache_rejection("rehydrate")
          next empty_snapshot
        end

        durable
      end
    end

    def migrate_legacy_cached_snapshot(snapshot)
      state_token = SecureRandom.hex(16)
      IpAccessOperationLock.call(ip_address: ip_address) do
        migrate_legacy_cached_snapshot_locked(snapshot, state_token: state_token)
      end
    rescue StandardError => e
      restore_legacy_active_cache(snapshot, state_token: state_token)
      log_state_failure("legacy_migration", e)
      snapshot
    end

    def migrate_legacy_cached_snapshot_locked(snapshot, state_token:)
      state = latest_durable_state
      if state
        restore_progress_cache(state)
        durable = durable_active_snapshot(state)
        unless durable
          cache.delete(active_key) unless write_inactive_cache(state: state)
          return empty_snapshot
        end

        written = write_active_cache(
          durable,
          strike_expires_at: durable_strike_expires_at(state),
          state_token: state_token
        )
        log_cache_rejection("legacy_rehydrate") unless written
        return durable
      end

      if legacy_scanner_reset_barrier?
        record_durable_revocation!
        cache.delete(active_key) unless write_inactive_cache
        return empty_snapshot
      end

      strike_expires_at = inferred_strike_expires_at(snapshot)
      record_durable_activation!(snapshot, strike_expires_at: strike_expires_at)
      written = write_active_cache(
        snapshot,
        strike_expires_at: strike_expires_at,
        state_token: state_token
      )
      raise ActivationError unless written

      snapshot
    end

    def active_snapshot_while_locked
      cached = cached_snapshot(migrate_legacy: false, restore_progress: true)
      return cached if cached&.fetch(:active)

      state = latest_durable_state
      durable = durable_active_snapshot(state)
      return unless durable

      restore_progress_cache(state)
      write_active_cache(
        durable,
        strike_expires_at: durable_strike_expires_at(state),
        state_token: SecureRandom.hex(16)
      )
      durable
    end

    def valid_active_payload?(payload)
      return false unless %i[tier strike_count duration_seconds expires_at_epoch].all? { |key| payload.key?(key) }

      valid_progress_values?(
        tier: payload[:tier],
        strike_count: payload[:strike_count],
        duration_seconds: payload[:duration_seconds]
      ) && payload[:expires_at_epoch].to_i.positive?
    end

    def valid_progress_values?(tier:, strike_count:, duration_seconds:)
      normalized_tier = tier.to_i
      normalized_duration = duration_seconds.to_i

      normalized_tier.between?(1, DURATIONS.length) &&
        strike_count.to_i >= ACTIVATION_STRIKE_COUNT &&
        normalized_duration == DURATIONS.fetch(normalized_tier - 1).to_i
    end

    def discard_invalid_active_payload
      cache.delete(active_key)
      nil
    end

    def discard_expired_active_payload
      cache.delete(active_key)
      nil
    end

    def durable_state_scope
      SecurityIpAction.where(
        ip_address: ip_address,
        action_type: DURABLE_STATE_ACTION_TYPE,
        source: DURABLE_STATE_SOURCE,
        matched_rule: DURABLE_STATE_MATCHED_RULE,
        status: DURABLE_STATE_STATUSES
      )
    end

    def latest_durable_state
      durable_state_scope.order(id: :desc).first
    end

    def latest_legacy_scanner_action
      SecurityIpAction
        .where(
          ip_address: ip_address,
          action_type: DURABLE_STATE_ACTION_TYPE,
          source: DURABLE_STATE_SOURCE,
          matched_rule: LEGACY_STATE_MATCHED_RULE,
          status: "active"
        )
        .order(expires_at: :desc, id: :desc)
        .first
    end

    def legacy_scanner_reset_barrier?
      SecurityIpAction
        .where(
          ip_address: ip_address,
          action_type: LEGACY_RESET_ACTION_TYPE,
          source: "manual_admin",
          matched_rule: LEGACY_RESET_MATCHED_RULE,
          status: "reset"
        )
        .where(
          "metadata @> ?::jsonb OR metadata ->> 'target' IN (?, ?)",
          { reset_targets: [ "scanner" ] }.to_json,
          "scanner",
          "all"
        )
        .exists?
    end

    def legacy_active_snapshot
      action = latest_legacy_scanner_action
      return unless action&.status == "active"
      return unless action.expires_at&.future?

      metadata = action.metadata.to_h.with_indifferent_access
      return unless metadata[:active] == true
      return unless valid_active_payload?(
        metadata.merge(expires_at_epoch: action.expires_at.to_i)
      )

      active_snapshot(
        tier: metadata.fetch(:tier),
        strike_count: metadata.fetch(:strike_count),
        duration_seconds: metadata.fetch(:duration_seconds),
        expires_at: action.expires_at
      )
    end

    def durable_active_snapshot(state)
      return unless state&.status == "active"
      return unless state.expires_at&.future?

      metadata = state.metadata.to_h.with_indifferent_access
      return unless valid_active_payload?(
        metadata.merge(expires_at_epoch: state.expires_at.to_i)
      )

      active_snapshot(
        tier: metadata.fetch(:tier),
        strike_count: metadata.fetch(:strike_count),
        duration_seconds: metadata.fetch(:duration_seconds),
        expires_at: state.expires_at
      )
    end

    def record_durable_activation!(snapshot, strike_expires_at:)
      now = Time.current
      SecurityIpAction.create!(
        ip_address: ip_address,
        action_type: DURABLE_STATE_ACTION_TYPE,
        source: DURABLE_STATE_SOURCE,
        status: "active",
        matched_rule: DURABLE_STATE_MATCHED_RULE,
        count: 1,
        first_seen_at: now,
        last_seen_at: now,
        expires_at: snapshot.fetch(:expires_at),
        metadata: durable_metadata(snapshot, strike_expires_at: strike_expires_at)
      )
    end

    def record_durable_revocation!
      now = Time.current
      SecurityIpAction.create!(
        ip_address: ip_address,
        action_type: DURABLE_STATE_ACTION_TYPE,
        source: DURABLE_STATE_SOURCE,
        status: "revoked",
        matched_rule: DURABLE_STATE_MATCHED_RULE,
        count: 1,
        first_seen_at: now,
        last_seen_at: now,
        expires_at: durable_revocation_expires_at,
        metadata: {
          active: false,
          tier: 0,
          strike_count: 0,
          duration_seconds: 0
        }
      )
    end

    def durable_revocation_expires_at
      [
        STRIKE_RETENTION.from_now,
        durable_state_scope.maximum(:expires_at)
      ].compact.max
    end

    def durable_metadata(snapshot, strike_expires_at:)
      {
        active: true,
        tier: snapshot.fetch(:tier),
        strike_count: snapshot.fetch(:strike_count),
        duration_seconds: snapshot.fetch(:duration_seconds),
        strike_expires_at_epoch: strike_expires_at.to_i
      }
    end

    def write_active_cache(snapshot, strike_expires_at:, state_token:)
      remaining = snapshot.fetch(:expires_at) - Time.current
      return false unless remaining.positive?

      cache.write(
        active_key,
        {
          active: true,
          durable: true,
          state_token: state_token,
          tier: snapshot.fetch(:tier),
          strike_count: snapshot.fetch(:strike_count),
          duration_seconds: snapshot.fetch(:duration_seconds),
          expires_at_epoch: snapshot.fetch(:expires_at).to_i,
          strike_expires_at_epoch: strike_expires_at.to_i
        },
        expires_in: remaining
      )
    end

    def write_inactive_cache(verification_token: nil, state: nil)
      expires_in = verification_token ? RESET_VERIFICATION_TTL : STRIKE_RETENTION
      payload = {
        active: false,
        verification_token: verification_token
      }.compact
      progress = durable_progress_metadata(state)
      payload.merge!(progress) if progress

      cache.write(
        active_key,
        payload,
        expires_in: expires_in
      )
    end

    def strike_expiry_for_activation
      state = latest_durable_state
      durable_strike_expires_at(state) || STRIKE_RETENTION.from_now
    end

    def durable_strike_expires_at(state)
      return unless state&.status == "active"

      epoch = state.metadata.to_h.with_indifferent_access[:strike_expires_at_epoch].to_i
      return unless epoch.positive?

      expires_at = Time.zone.at(epoch)
      expires_at if expires_at.future?
    end

    def inferred_strike_expires_at(snapshot)
      tier = snapshot.fetch(:tier)
      elapsed_before_tier = DURATIONS.first(tier - 1).sum
      window_started_at =
        snapshot.fetch(:expires_at) -
        snapshot.fetch(:duration_seconds).seconds -
        elapsed_before_tier
      window_started_at + STRIKE_RETENTION
    end

    def restore_progress_cache(state)
      strike_expires_at = durable_strike_expires_at(state)
      return unless strike_expires_at

      metadata = state.metadata.to_h.with_indifferent_access
      restore_progress_cache_from_metadata(
        metadata.merge(strike_expires_at_epoch: strike_expires_at.to_i)
      )
    end

    def restore_progress_cache_from_metadata(metadata)
      strike_expires_at = Time.zone.at(metadata[:strike_expires_at_epoch].to_i)
      return unless strike_expires_at.future?
      return unless valid_progress_values?(
        tier: metadata[:tier],
        strike_count: metadata[:strike_count],
        duration_seconds: metadata[:duration_seconds]
      )

      remaining = strike_expires_at - Time.current
      return unless remaining.positive?

      strike_count = [ cache.read(strike_key).to_i, metadata.fetch(:strike_count).to_i ].max
      tier = [ cache.read(tier_key).to_i, metadata.fetch(:tier).to_i ].max
      cache.write(strike_key, strike_count, expires_in: remaining)
      cache.write(tier_key, tier, expires_in: remaining)
    end

    def durable_progress_metadata(state)
      strike_expires_at = durable_strike_expires_at(state)
      return unless strike_expires_at

      metadata = state.metadata.to_h.with_indifferent_access
      return unless valid_progress_values?(
        tier: metadata[:tier],
        strike_count: metadata[:strike_count],
        duration_seconds: metadata[:duration_seconds]
      )

      {
        durable_progress: true,
        tier: metadata.fetch(:tier).to_i,
        strike_count: metadata.fetch(:strike_count).to_i,
        duration_seconds: metadata.fetch(:duration_seconds).to_i,
        strike_expires_at_epoch: strike_expires_at.to_i
      }
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

    def progress_keys
      [ strike_key, probe_gate_key, tier_key ]
    end

    def reset_verified?(verification_token)
      values = cache.read_multi(reset_verification_key, active_key, *progress_keys)
      inactive_payload = values[active_key]
      inactive_token =
        inactive_payload.to_h.with_indifferent_access[:verification_token] if inactive_payload.respond_to?(:to_h)

      values[reset_verification_key] == verification_token &&
        inactive_token == verification_token &&
        progress_keys.none? { |key| values.key?(key) }
    end

    def restore_legacy_active_cache(snapshot, state_token:)
      delete_active_cache_if_token(state_token)
      write_legacy_active_cache(snapshot)
    rescue StandardError => e
      log_cache_failure("legacy_restore", e)
    end

    def write_legacy_active_cache(snapshot)
      remaining = snapshot.fetch(:expires_at) - Time.current
      return false unless remaining.positive?

      cache.write(
        active_key,
        {
          tier: snapshot.fetch(:tier),
          strike_count: snapshot.fetch(:strike_count),
          duration_seconds: snapshot.fetch(:duration_seconds),
          expires_at_epoch: snapshot.fetch(:expires_at).to_i
        },
        expires_in: remaining
      )
    end

    def delete_reset_verification_key_if_token(verification_token)
      return if ip_address.blank? || verification_token.blank?

      cached_token = cache.read(reset_verification_key)
      cache.delete(reset_verification_key) if cached_token == verification_token
    rescue StandardError => e
      log_cache_failure("reset_verification_cleanup", e)
    end

    def delete_active_cache_if_token(state_token)
      return if state_token.blank?

      payload = cache.read(active_key)
      return unless payload.respond_to?(:to_h)
      return unless payload.to_h.with_indifferent_access[:state_token] == state_token

      cache.delete(active_key)
    rescue StandardError => e
      log_cache_failure("activation_cleanup", e)
    end

    def delete_inactive_cache_if_token(verification_token)
      return if verification_token.blank?

      payload = cache.read(active_key)
      return unless payload.respond_to?(:to_h)
      return unless payload.to_h.with_indifferent_access[:verification_token] == verification_token

      cache.delete(active_key)
    rescue StandardError => e
      log_cache_failure("reset_cleanup", e)
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

    def log_state_failure(operation, error)
      Rails.logger.warn(
        "[Security::AdaptiveScannerRestriction] state_failure operation=#{operation} class=#{error.class.name}"
      )
    end
  end
end
