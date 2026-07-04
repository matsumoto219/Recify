module SensitiveMetadataKeys
  PROVIDER_DETAIL_KEYS = %w[
    endpoint
    ocp-apim-subscription-key
    ocp_apim_subscription_key
    operation-location
    operation_location
    subscription-key
    subscription_key
  ].freeze

  PROVIDER_DETAIL_KEY_PATTERN = /\A(?:endpoint|operation[_-]?location|(?:ocp[_-]apim[_-])?subscription[_-]?key)\z/i
end
