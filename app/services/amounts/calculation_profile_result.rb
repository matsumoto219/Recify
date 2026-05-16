# frozen_string_literal: true

module Amounts
  class CalculationProfileResult
    EMPTY_ATTRIBUTES = {
      profile: nil,
      score: nil,
      candidates: [],
      warnings: [],
      applied_profile: nil
    }.freeze

    attr_reader :profile, :score, :candidates, :warnings, :applied_profile

    def self.wrap(value)
      value.is_a?(self) ? value : new(value)
    end

    def initialize(attributes = nil)
      attributes = EMPTY_ATTRIBUTES.merge((attributes || {}).symbolize_keys)

      @profile = attributes[:profile]
      @score = attributes[:score]
      @candidates = Array(attributes[:candidates])
      @warnings = Array(attributes[:warnings])
      @applied_profile = attributes[:applied_profile]
    end

    def warning_codes
      warnings.filter_map do |warning|
        Amounts::MismatchCodes.code(warning.to_sym)
      end
    end

    def present?
      profile.present? ||
        !score.nil? ||
        candidates.present? ||
        warnings.present?
    end

    def with_applied_profile(profile)
      self.class.new(to_h.merge(applied_profile: profile))
    end

    def to_h
      {
        profile: profile,
        score: score,
        candidates: candidates,
        warnings: warnings
      }
    end
  end
end
