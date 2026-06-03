module Ai
  module Providers
    class Base
      # Provider adapters perform one provider-specific API attempt.
      # Ai::ProviderExecutor owns retry/backoff and common metrics enrichment.
      def call(_input)
        raise NotImplementedError, "provider client must implement #call"
      end

      def retry_policy
        nil
      end
    end
  end
end
