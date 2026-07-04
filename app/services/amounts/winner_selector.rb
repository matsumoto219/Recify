# frozen_string_literal: true

module Amounts
  class WinnerSelector
    def initialize(candidates)
      @candidates = Array(candidates)
    end

    def call
      pool = selectable_candidates

      pool.min_by do |candidate|
        [
          candidate.score.to_i,
          candidate.candidate_id
        ]
      end
    end

    def no_safe_candidate?
      candidates.present? && candidates.none?(&:accepted?)
    end

    private

    attr_reader :candidates

    def selectable_candidates
      candidates.reject(&:rejected?).presence || candidates
    end
  end
end
