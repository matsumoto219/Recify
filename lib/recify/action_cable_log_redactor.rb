require "delegate"

module Recify
  module ActionCableLogRedactor
    FILTERED_STREAM = "[FILTERED_ACTION_CABLE_STREAM]".freeze
    FILTERED_PAYLOAD = "[FILTERED_ACTION_CABLE_PAYLOAD]".freeze

    SIGNED_STREAM_JSON_PATTERN = /(\\?"signed_stream_name\\?"\s*:\s*\\?")[^"\\]*(\\?")/
    SIGNED_STREAM_HASH_PATTERN = /((?:["']signed_stream_name["']|:signed_stream_name)\s*=>\s*["'])[^"']*(["'])/
    SIGNED_STREAM_QUERY_PATTERN = /(\bsigned_stream_name=)[^&\s]+/
    SIGNED_STREAM_CAPABILITY_PATTERN = /(?<![A-Za-z0-9+\/=_-])[A-Za-z0-9+\/=]{20,}--[0-9a-f]{64}(?![A-Za-z0-9+\/=_-])/i
    VERIFIED_STREAM_PATTERN = /(?<![A-Za-z0-9+\/=])Z2lkOi8v[A-Za-z0-9+\/=]+(?::[a-z0-9_]+)+(?![A-Za-z0-9_])/i
    BROADCAST_PATTERN = /\A(\[ActionCable\]\s+Broadcasting to ).*\z/m
    TRANSMIT_PATTERN = /\A(.+? transmitting ).+? \(via streamed from .+\)\z/m
    STREAM_ACTIVITY_PATTERN = /(\b(?:is|stopped) streaming from )\S+/

    module_function

    def redact(value)
      return value if value.nil?

      value.to_s.dup
        .gsub(SIGNED_STREAM_JSON_PATTERN, "\\1#{FILTERED_STREAM}\\2")
        .gsub(SIGNED_STREAM_HASH_PATTERN, "\\1#{FILTERED_STREAM}\\2")
        .gsub(SIGNED_STREAM_QUERY_PATTERN, "\\1#{FILTERED_STREAM}")
        .gsub(SIGNED_STREAM_CAPABILITY_PATTERN, FILTERED_STREAM)
        .sub(BROADCAST_PATTERN, "\\1#{FILTERED_STREAM}: #{FILTERED_PAYLOAD}")
        .sub(TRANSMIT_PATTERN, "\\1#{FILTERED_PAYLOAD} (via #{FILTERED_STREAM})")
        .gsub(STREAM_ACTIVITY_PATTERN, "\\1#{FILTERED_STREAM}")
        .gsub(VERIFIED_STREAM_PATTERN, FILTERED_STREAM)
    end
  end

  class ActionCableLogger < SimpleDelegator
    %i[debug info warn error fatal unknown].each do |severity|
      define_method(severity) do |message = nil, &block|
        if block
          __getobj__.public_send(severity, ActionCableLogRedactor.redact(message)) do
            ActionCableLogRedactor.redact(block.call)
          end
        else
          __getobj__.public_send(severity, ActionCableLogRedactor.redact(message))
        end
      end
    end

    def add(severity, message = nil, progname = nil, &block)
      if block
        __getobj__.add(severity, ActionCableLogRedactor.redact(message), progname) do
          ActionCableLogRedactor.redact(block.call)
        end
      else
        __getobj__.add(severity, ActionCableLogRedactor.redact(message), progname)
      end
    end

    alias_method :log, :add

    def <<(message)
      __getobj__ << ActionCableLogRedactor.redact(message)
    end
  end
end
