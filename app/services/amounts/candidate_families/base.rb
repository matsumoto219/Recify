# frozen_string_literal: true

module Amounts
  module CandidateFamilies
    class Base
      def initialize(generator)
        @generator = generator
      end

      def call
        raise NotImplementedError, "#{self.class.name} must implement #call"
      end

      private

      attr_reader :generator

      def method_missing(method_name, ...)
        return generator.__send__(method_name, ...) if generator.respond_to?(method_name, true)

        super
      end

      def respond_to_missing?(method_name, include_private = false)
        generator.respond_to?(method_name, true) || super
      end
    end
  end
end
