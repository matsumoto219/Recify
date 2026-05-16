module Ocr
  class AvailabilityChecker
    class << self
      def call
        new.call
      end
    end

    def initialize(client: Ocr::Client.new(image: nil))
      @client = client
    end

    def call
      client.available? == true
    rescue StandardError => e
      Rails.logger.warn(
        "[OCR::AvailabilityChecker] unavailable class=#{e.class} message=#{e.message}"
      )
      false
    end

    private

    attr_reader :client
  end
end
