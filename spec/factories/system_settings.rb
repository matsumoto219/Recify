FactoryBot.define do
  factory :system_setting do
    key { "feature.receipt_logo_display_enabled" }
    value { SystemSettings.stored_value(true) }
    updated_by_user { nil }
  end
end
