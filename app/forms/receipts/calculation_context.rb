# frozen_string_literal: true

class Receipts::CalculationContext
  SCHEMA_VERSION = 1
  PURPOSE = "receipt_calculation_context_v1"
  MAX_TOKEN_BYTES = 4_096
  MAX_RECORD_ID = 9_223_372_036_854_775_807
  MAX_LOCK_VERSION = 2_147_483_647
  APPLICATION_DEFAULTS = {
    "tax_rounding_mode" => "floor",
    "discount_rounding_mode" => "round",
    "default_item_tax_inclusion" => "gross"
  }.freeze
  SETTING_VALUES = {
    "tax_rounding_mode" => ReceiptCalculationSettings::ROUNDING_MODES,
    "discount_rounding_mode" => ReceiptCalculationSettings::ROUNDING_MODES,
    "default_item_tax_inclusion" => ReceiptCalculationSettings::TAX_INCLUSIONS
  }.freeze
  ORIGINS = %w[form_default application_default].freeze
  ROOT_KEYS = %w[schema_version user_id target defaults].freeze
  ENTRY_KEYS = %w[value origin].freeze
  private_constant :SCHEMA_VERSION, :PURPOSE, :MAX_TOKEN_BYTES, :MAX_RECORD_ID, :MAX_LOCK_VERSION,
    :APPLICATION_DEFAULTS, :SETTING_VALUES, :ORIGINS, :ROOT_KEYS, :ENTRY_KEYS

  Result = Data.define(:token, :defaults) do
    def default_for(key)
      defaults.dig(key, "value")
    end

    def origin_for(key)
      defaults.dig(key, "origin")
    end
  end

  class << self
    def build(user:, receipt:)
      return unless valid_owner?(user, receipt)

      target = target_for(receipt)
      return unless target

      defaults = SETTING_VALUES.to_h do |key, allowed_values|
        value = user.public_send(key)
        from_user = allowed_token?(value, allowed_values)
        entry = {
          "value" => from_user ? value : APPLICATION_DEFAULTS.fetch(key),
          "origin" => from_user ? "form_default" : "application_default"
        }
        [ key, entry ]
      end
      payload = {
        "schema_version" => SCHEMA_VERSION,
        "user_id" => user.id,
        "target" => target,
        "defaults" => defaults
      }
      result(verifier.generate(payload, purpose: PURPOSE), defaults)
    end

    def verify(token:, user:, receipt:)
      return unless valid_token?(token) && valid_owner?(user, receipt)

      payload = verifier.verified(token, purpose: PURPOSE)
      return unless valid_payload?(payload, user, receipt)

      result(token, payload.fetch("defaults"))
    end

    private

    def verifier
      Rails.application.message_verifier("receipt_calculation_context")
    end

    def result(token, defaults)
      frozen_defaults = defaults.to_h do |key, entry|
        [ key.dup.freeze, entry.transform_values { |value| value.dup.freeze }.freeze ]
      end.freeze
      Result.new(token: token.dup.freeze, defaults: frozen_defaults)
    end

    def valid_owner?(user, receipt)
      valid_record_id?(user.id) &&
        (receipt.user_id == user.id || (!receipt.persisted? && receipt.user_id.nil?))
    end

    def target_for(receipt)
      return { "new_form_nonce" => SecureRandom.hex(16) } unless receipt.persisted?
      return unless valid_record_id?(receipt.id) && valid_lock_version?(receipt.lock_version)

      { "id" => receipt.id, "lock_version" => receipt.lock_version }
    end

    def valid_payload?(payload, user, receipt)
      exact_keys?(payload, ROOT_KEYS) &&
        payload["schema_version"].is_a?(Integer) &&
        payload["schema_version"] == SCHEMA_VERSION &&
        valid_record_id?(payload["user_id"]) &&
        payload["user_id"] == user.id &&
        valid_target?(payload["target"], receipt) &&
        valid_defaults?(payload["defaults"])
    end

    def valid_target?(target, receipt)
      if receipt.persisted?
        exact_keys?(target, %w[id lock_version]) &&
          valid_record_id?(target["id"]) &&
          valid_lock_version?(target["lock_version"]) &&
          target["id"] == receipt.id &&
          target["lock_version"] == receipt.lock_version
      else
        exact_keys?(target, %w[new_form_nonce]) &&
          target["new_form_nonce"].is_a?(String) &&
          target["new_form_nonce"].bytesize == 32 &&
          target["new_form_nonce"].ascii_only? &&
          /\A[0-9a-f]{32}\z/.match?(target["new_form_nonce"])
      end
    end

    def valid_defaults?(defaults)
      return false unless exact_keys?(defaults, SETTING_VALUES.keys)

      SETTING_VALUES.all? do |key, allowed_values|
        entry = defaults[key]
        exact_keys?(entry, ENTRY_KEYS) &&
          allowed_token?(entry["value"], allowed_values) &&
          allowed_token?(entry["origin"], ORIGINS) &&
          (entry["origin"] != "application_default" || entry["value"] == APPLICATION_DEFAULTS.fetch(key))
      end
    end

    def valid_token?(token)
      token.is_a?(String) &&
        token.bytesize.between?(1, MAX_TOKEN_BYTES) &&
        token.valid_encoding? &&
        token.ascii_only? &&
        /\A[A-Za-z0-9+\/_=.\-]+\z/.match?(token)
    end

    def exact_keys?(value, allowed)
      value.is_a?(Hash) && value.size == allowed.size && (value.keys - allowed).empty?
    end

    def allowed_token?(value, allowed)
      value.is_a?(String) &&
        value.bytesize <= 24 &&
        value.valid_encoding? &&
        value.encoding.ascii_compatible? &&
        allowed.include?(value)
    end

    def valid_record_id?(value)
      value.is_a?(Integer) && value.between?(1, MAX_RECORD_ID)
    end

    def valid_lock_version?(value)
      value.is_a?(Integer) && value.between?(0, MAX_LOCK_VERSION)
    end
  end
end
