module Ai
  class ProviderResult
    attr_reader :provider, :model, :payload, :metrics, :response_id

    def initialize(provider:, payload:, model: nil, metrics: nil, response_id: nil)
      @provider = safe_string(provider)
      @model = safe_string(model)
      @payload = payload || {}
      @response_id = safe_string(response_id || normalized_hash(metrics)[:response_id])
      @metrics = Ai::ProviderMetrics.merge(
        metrics,
        provider: @provider,
        model: @model,
        response_id: @response_id
      )
    end

    def success?
      normalized_hash(payload)[:success] == true
    end

    private

    def safe_string(value)
      value.to_s.presence if value.present?
    end

    def normalized_hash(value)
      return value.with_indifferent_access if value.respond_to?(:with_indifferent_access)

      {}.with_indifferent_access
    end
  end
end
