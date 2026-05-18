module StorageHelper
  STORAGE_UNITS = [
    [ "GB", 1.gigabyte ],
    [ "MB", 1.megabyte ],
    [ "KB", 1.kilobyte ]
  ].freeze

  def format_storage_size(bytes)
    bytes = bytes.to_i
    return "0" if bytes <= 0

    unit_label, unit_bytes = STORAGE_UNITS.find { |_label, size| bytes >= size }
    return "#{bytes}B" if unit_label.blank?

    value = bytes.to_f / unit_bytes
    precision = value < 10 ? 1 : 0
    formatted = number_with_precision(
      value,
      precision: precision,
      strip_insignificant_zeros: true,
      delimiter: ","
    )

    "#{formatted}#{unit_label}"
  end

  def storage_usage_meter_percentage(usage)
    usage.usage_percentage.clamp(0, 100)
  end

  def storage_usage_meter_color(usage)
    case usage.state
    when :error
      "var(--state-error)"
    when :warning
      "var(--state-warning)"
    else
      "var(--brand-primary)"
    end
  end

  def storage_usage_state_text_class(usage)
    case usage.state
    when :error
      "token-text-error"
    when :warning
      "token-text-warning"
    else
      "token-text-brand"
    end
  end

  def storage_usage_state_box_class(usage)
    case usage.state
    when :error
      "token-border-error-soft token-bg-error-soft token-text-error"
    when :warning
      "token-border-soft token-bg-warning-soft token-text-warning"
    else
      "token-border-soft token-bg-info-soft token-text-base"
    end
  end
end
