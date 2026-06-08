# frozen_string_literal: true

module Amounts
  class WinnerSelector
    def initialize(candidates)
      @candidates = Array(candidates)
    end

    def call
      pool = candidates.reject(&:rejected?).presence || candidates

      pool.min_by do |candidate|
        [
          candidate.score.to_i,
          candidate.candidate_id
        ]
      end
    end

    private

    attr_reader :candidates
  end
end
