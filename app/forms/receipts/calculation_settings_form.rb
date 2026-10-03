# frozen_string_literal: true

class Receipts::CalculationSettingsForm
  CONTROL_VALUES = ReceiptCalculationSettings::SETTING_VALUES.except("tax_rounding_scope").freeze
  REQUIRED_KEYS = %w[tax_rounding_mode discount_rounding_mode tax_rounding_scope].freeze
  ITEM_CONTROL_KEYS = %w[pricing_source_kind input_tax_inclusion reference_price_tax_inclusion].freeze
  DEFAULT_VALUES = {
    "tax_rounding_mode" => "floor",
    "discount_rounding_mode" => "round",
    "tax_rounding_scope" => "per_tax_rate_group",
    "purchase_adjustment_tax_inclusion" => "gross"
  }.freeze
  private_constant :CONTROL_VALUES, :REQUIRED_KEYS, :ITEM_CONTROL_KEYS, :DEFAULT_VALUES

  Result = Data.define(:attributes, :errors) do
    def success?
      errors.empty?
    end
  end

  def initialize(receipt:, context:, existing_purchase_adjustments: false)
    @receipt = receipt
    @context = context if context.is_a?(Receipts::CalculationContext::Result)
    @existing_purchase_adjustments = existing_purchase_adjustments == true
    @saved_settings = ReceiptCalculationSettings.parse(receipt.calculation_settings)
    @invalid_saved_settings = !receipt.calculation_settings.nil? && @saved_settings.nil?
    profile = accepted_profile(receipt.amount_calculation_profile)
    @legacy_basis = legacy_basis(profile)
    @legacy_entries = legacy_entries(profile).freeze
  end

  def invalid_saved_settings?
    @invalid_saved_settings
  end

  def value_for(key)
    display_entry(key)&.fetch("value")
  end

  def origin_for(key)
    display_entry(key)&.fetch("origin")
  end

  def fallback?(key)
    !invalid_saved_settings? && recorded_entry(key).nil? && !display_entry(key).nil?
  end

  def item_value_for(item)
    item_entry(item, display: true)&.fetch("value")
  end

  def item_origin_for(item)
    item_entry(item, display: true)&.fetch("origin")
  end

  def resolve(submitted:, monetary_change:, purchase_adjustments_present:)
    errors = control_errors(submitted)
    return result(errors: errors) if errors.any? || monetary_change != true
    return result(errors: { "calculation_settings" => :unavailable }) if invalid_saved_settings?

    attributes = @saved_settings&.to_h || { "schema_version" => ReceiptCalculationSettings::SCHEMA_VERSION }
    required_keys = REQUIRED_KEYS.dup
    required_keys << "purchase_adjustment_tax_inclusion" if purchase_adjustments_present == true
    required_keys.each do |key|
      resolved = resolved_entry(key, submitted)
      if resolved
        attributes[key] = resolved
      else
        errors[key] = missing_reason(key)
      end
    end
    return result(errors: errors) if errors.any?
    return result if attributes == @saved_settings&.to_h

    result(attributes: { "calculation_settings" => attributes })
  end

  def resolve_item(item:, submitted:, monetary_change:)
    errors = item_control_errors(item, submitted)
    return result(errors: errors) if errors.any? || monetary_change != true
    return result(errors: { "calculation_settings" => :unavailable }) if invalid_saved_settings?

    kind = submitted.fetch("pricing_source_kind", item&.pricing_source_kind)
    field = basis_field(kind)
    current = item_entry(item, display: false)
    if kind.nil?
      changed = submitted.key?(field) && submitted[field] != item_value_for(item)
      return result(errors: changed ? { "pricing_source_kind" => :missing } : {})
    end

    resolved = submitted_entry(submitted, field, current)
    return result(errors: { field => :missing }) unless resolved

    attributes = {
      field => resolved.fetch("value"),
      "tax_inclusion_origin" => resolved.fetch("origin")
    }
    if kind != item&.pricing_source_kind
      inactive_field = kind == "reference_quantity_price" ? "input_tax_inclusion" : "reference_price_tax_inclusion"
      attributes[inactive_field] = nil
    else
      attributes.delete_if { |key, value| item && item.public_send(key) == value }
    end
    result(attributes: attributes)
  end

  private

  def display_entry(key)
    return if invalid_saved_settings?
    return unless ReceiptCalculationSettings::SETTING_VALUES.key?(key)

    recorded_entry(key) || fallback_entry(key, display: true)
  end

  def recorded_entry(key)
    saved_value = @saved_settings&.value_for(key)
    return entry(saved_value, @saved_settings.origin_for(key)) if saved_value

    @legacy_entries[key]
  end

  def resolved_entry(key, submitted)
    current = recorded_entry(key) || fallback_entry(key, display: false)
    submitted_entry(submitted, key, current)
  end

  def submitted_entry(submitted, key, current)
    return current unless submitted.key?(key)
    return current if current && current.fetch("value") == submitted[key]

    entry(submitted[key], "manual")
  end

  def fallback_entry(key, display:)
    return if key == "purchase_adjustment_tax_inclusion" && @existing_purchase_adjustments

    if %w[tax_rounding_scope purchase_adjustment_tax_inclusion].include?(key)
      entry(DEFAULT_VALUES.fetch(key), "application_default")
    else
      context_entry(key) || (entry(DEFAULT_VALUES.fetch(key), "application_default") if display)
    end
  end

  def context_entry(key)
    return unless @context

    value = @context.default_for(key)
    origin = @context.origin_for(key)
    allowed_values = key == "default_item_tax_inclusion" ? ReceiptCalculationSettings::TAX_INCLUSIONS : ReceiptCalculationSettings::ROUNDING_MODES
    return unless allowed_value?(value, allowed_values)
    return unless %w[form_default application_default].include?(origin)

    entry(value, origin)
  end

  def item_entry(item, display:)
    if item&.persisted?
      kind = item.pricing_source_kind
      value = item.public_send(basis_field(kind)) if ReceiptItem::PRICING_SOURCE_KINDS.include?(kind)
      if allowed_value?(value, ReceiptCalculationSettings::TAX_INCLUSIONS)
        origin = item.tax_inclusion_origin
        origin = "legacy_record" unless ReceiptCalculationSettings::ORIGINS.include?(origin)
        return entry(value, origin)
      end
      return entry("gross", "legacy_record") if kind == "explicit_line_total"
      if @receipt.respond_to?(:legacy_gross_item_projection?) &&
          @receipt.legacy_gross_item_projection?(pricing_source_kind: kind)
        return entry("gross", "legacy_record")
      end
      return entry(@legacy_basis, "legacy_record") if @legacy_basis
    end

    context_entry("default_item_tax_inclusion") || (entry("gross", "application_default") if display)
  end

  def basis_field(kind)
    kind == "reference_quantity_price" ? "reference_price_tax_inclusion" : "input_tax_inclusion"
  end

  def control_errors(submitted)
    return { "calculation_settings" => :invalid } unless bounded_controls?(submitted, CONTROL_VALUES.keys)

    submitted.each_with_object({}) do |(key, value), errors|
      errors[key] = :invalid unless allowed_value?(value, CONTROL_VALUES.fetch(key))
    end
  end

  def item_control_errors(item, submitted)
    return { "input_tax_inclusion" => :invalid } unless bounded_controls?(submitted, ITEM_CONTROL_KEYS)

    kind = submitted.fetch("pricing_source_kind", item&.pricing_source_kind)
    if submitted.key?("pricing_source_kind") && kind.nil? && item&.pricing_source_kind
      return { "pricing_source_kind" => :invalid }
    end
    unless kind.nil? || allowed_value?(kind, ReceiptItem::PRICING_SOURCE_KINDS)
      return { "pricing_source_kind" => :invalid }
    end

    active_field = basis_field(kind)
    submitted.each_with_object({}) do |(key, value), errors|
      next if key == "pricing_source_kind"

      errors[key] = :invalid unless key == active_field && allowed_value?(value, ReceiptCalculationSettings::TAX_INCLUSIONS)
    end
  end

  def bounded_controls?(submitted, allowed)
    submitted.is_a?(Hash) &&
      submitted.size <= allowed.size &&
      (submitted.keys - allowed).empty?
  end

  def allowed_value?(value, allowed)
    value.is_a?(String) &&
      value.bytesize <= 32 &&
      value.valid_encoding? &&
      value.encoding.ascii_compatible? &&
      allowed.include?(value)
  end

  def missing_reason(key)
    if key == "purchase_adjustment_tax_inclusion" && @existing_purchase_adjustments
      :confirmation_required
    else
      :missing
    end
  end

  def accepted_profile(value)
    return unless value.is_a?(Hash)
    return unless value["schema_version"].is_a?(Integer) && value["schema_version"] == 1
    return unless value["selected_candidate_status"] == "accepted"
    return if value.key?("profile") && !value["profile"].nil? && !value["profile"].is_a?(Hash)

    engine = value["amount_engine"]
    return if engine && !engine.is_a?(Hash)
    if engine
      return unless [ nil, false ].include?(engine["no_safe_candidate"])
      if engine.key?("schema_version")
        return unless engine["schema_version"].is_a?(Integer) && engine["schema_version"] == 1
      end
      return unless [ nil, "accepted" ].include?(engine["selected_candidate_status"])
    end
    value
  end

  def legacy_entries(snapshot)
    return {} unless snapshot

    profile = snapshot["profile"] || {}
    rounding = snapshot["rounding_mode"].is_a?(Hash) ? snapshot["rounding_mode"] : {}
    values = {
      "tax_rounding_mode" => profile["tax_rounding_mode"] || rounding["tax"],
      "discount_rounding_mode" => profile["discount_rounding_mode"] || rounding["discount"],
      "tax_rounding_scope" => legacy_rounding_scope(snapshot),
      "purchase_adjustment_tax_inclusion" => @existing_purchase_adjustments ? @legacy_basis : nil
    }
    values.each_with_object({}) do |(key, value), entries|
      next unless allowed_value?(value, ReceiptCalculationSettings::SETTING_VALUES.fetch(key))

      entries[key] = entry(value, "legacy_record")
    end
  end

  def legacy_rounding_scope(snapshot)
    engine = snapshot["amount_engine"]
    candidate = engine&.fetch("selected_candidate", nil)
    return unless candidate.is_a?(Hash)

    candidate_id = engine["selected_candidate_id"]
    return unless candidate_id.is_a?(String) && candidate_id.bytesize.between?(1, 128)
    return unless candidate_id == candidate["candidate_id"]
    return unless candidate["hard_reject_reasons"] == []

    candidate["rounding_scope"]
  end

  def legacy_basis(snapshot)
    return unless snapshot

    profile = snapshot["profile"]
    semantics = if profile.is_a?(Hash) && profile.key?("receipt_tax_basis")
      profile
    else
      selected_basis = snapshot.dig("amount_engine", "selected_basis")
      Receipt::PROFILELESS_SELECTED_BASIS_SOURCE_SEMANTICS[selected_basis]
    end
    return unless semantics

    case [ semantics["receipt_tax_basis"], semantics["item_amount_basis"] ]
    when [ "tax_added_to_subtotal", "line_total_as_net" ]
      "net"
    when [ "total_includes_tax", "line_total_as_recorded" ]
      "gross"
    end
  end

  def entry(value, origin)
    { "value" => value.dup.freeze, "origin" => origin.dup.freeze }.freeze
  end

  def result(attributes: {}, errors: {})
    attributes.each_value do |value|
      next unless value.is_a?(Hash)

      value.each_value do |setting|
        next unless setting.is_a?(Hash)

        setting.each_value(&:freeze)
        setting.freeze
      end
      value.freeze
    end
    Result.new(attributes: attributes.freeze, errors: errors.freeze)
  end
end
