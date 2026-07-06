module Recify
  module ActiveStorageLogRedactor
    FILTERED_URL = "[FILTERED_ACTIVE_STORAGE_URL]".freeze
    FILTERED_KEY = "[FILTERED_ACTIVE_STORAGE_KEY]".freeze

    SENSITIVE_ROUTE_PATTERN = %r{
      (?:https?://[^/\s"')]+)?
      /rails/active_storage/
      (?:
        blobs/(?:redirect/|proxy/)?[^\s"')]+
        |representations/(?:redirect/|proxy/)?[^\s"')]+
        |disk/[^\s"')]+
      )
    }ix

    module_function

    def redact(value)
      return value if value.nil?

      value.to_s.gsub(SENSITIVE_ROUTE_PATTERN, FILTERED_URL)
    end
  end
end
