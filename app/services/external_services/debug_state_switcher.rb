module ExternalServices
  class DebugStateSwitcher
    STATES = %w[ok degraded down reset].freeze
    FAILURE_ERROR_CODE = "external_service_unavailable"

    class NotAvailableError < StandardError; end

    class << self
      def call(service:, state:, actor: nil, reason: nil, error_code: FAILURE_ERROR_CODE, requested_at: Time.current)
        ensure_available!

        new(
          service: service,
          state: state,
          actor: actor,
          reason: reason,
          error_code: error_code,
          requested_at: requested_at
        ).call
      end

      def available?
        Rails.env.development? || Rails.env.test?
      end

      def ensure_available!
        return if available?

        raise NotAvailableError, "External service debug switching is only available in development or test"
      end
    end

    def initialize(service:, state:, actor: nil, reason: nil, error_code: FAILURE_ERROR_CODE, requested_at: Time.current)
      @service = normalize_service(service)
      @state = normalize_state(state)
      @actor = actor
      @reason = reason
      @error_code = normalize_error_code(error_code)
      @requested_at = requested_at
    end

    def call
      ensure_available!

      case state
      when "ok", "reset"
        StatusStore.reset!(service)
      when "degraded"
        mark_failures!(StatusStore::DEGRADED_THRESHOLD)
      when "down"
        mark_failures!(StatusStore::DOWN_THRESHOLD)
      end

      {
        service: service.to_s,
        requested_state: state,
        actor_id: actor&.id,
        reason: reason,
        requested_at: requested_at&.iso8601,
        snapshot: StatusStore.snapshot(service)
      }
    end

    private

    attr_reader :service, :state, :actor, :reason, :error_code, :requested_at

    def ensure_available!
      self.class.ensure_available!
    end

    def mark_failures!(count)
      StatusStore.reset!(service)
      count.times { StatusStore.mark_failure!(service, error_code: error_code) }
    end

    def normalize_service(value)
      service = value.to_s.strip.to_sym
      return service if StatusStore::SERVICES.include?(service)

      raise ArgumentError, "Unsupported service: #{value}"
    end

    def normalize_state(value)
      state = value.to_s.strip
      return state if STATES.include?(state)

      raise ArgumentError, "Unsupported state: #{value}"
    end

    def normalize_error_code(value)
      code = value.to_s.presence || FAILURE_ERROR_CODE
      return code if StatusStore.external_error?(code)

      FAILURE_ERROR_CODE
    end
  end
end
