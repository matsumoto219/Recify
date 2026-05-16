module Ai
  class AvailabilityChecker
    HEALTH_CHECK_INPUT = {
      filtered_content: "AI service health check",
      candidates: {},
      items: [],
      meta: { availability_check: true }
    }.freeze

    class << self
      def call
        new.call
      end
    end

    def initialize(client: Ai::Client.new)
      @client = client
    end

    def call
      result = client.call(HEALTH_CHECK_INPUT)
      result.respond_to?(:[]) && result[:success] == true
    rescue StandardError => e
      Rails.logger.warn(
        "[AI::AvailabilityChecker] unavailable class=#{e.class} message=#{e.message}"
      )
      false
    end

    private

    attr_reader :client
  end
end
