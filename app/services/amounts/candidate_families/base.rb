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

      def delegate(method_name)
        generator.__send__(method_name)
      end
    end
  end
end
