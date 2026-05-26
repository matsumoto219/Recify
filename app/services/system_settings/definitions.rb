module SystemSettings
  class Definitions
    ALL = [
      Definition.new(
        key: "feature.receipt_image_preprocess_enabled",
        category: "feature_flag",
        value_type: "boolean",
        default: false,
        editable: true,
        risk_level: "medium"
      ),
      Definition.new(
        key: "feature.receipt_logo_display_enabled",
        category: "feature_flag",
        value_type: "boolean",
        default: false,
        editable: true,
        risk_level: "low"
      ),
      Definition.new(
        key: "ui.maintenance_notice_enabled",
        category: "ui_toggle",
        value_type: "boolean",
        default: false,
        editable: true,
        risk_level: "low"
      ),
      Definition.new(
        key: "limits.receipt_upload_soft_limit",
        category: "soft_limit",
        value_type: "integer",
        default: 100,
        editable: true,
        risk_level: "medium",
        min: 1,
        max: 1000
      )
    ].index_by(&:key).freeze

    class << self
      def all
        ALL
      end
    end
  end
end
