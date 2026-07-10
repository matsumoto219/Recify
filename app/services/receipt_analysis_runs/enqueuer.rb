module ReceiptAnalysisRuns
  class Enqueuer
    ERROR_CODE = "analysis_enqueue_failed".freeze
    ERROR_MESSAGE = ERROR_CODE

    class << self
      def call(run, job_class:)
        new(run, job_class:).call
      end
    end

    def initialize(run, job_class:)
      @run = run
      @job_class = job_class
    end

    def call
      job_class.perform_later(run_id: run.id)
    rescue StandardError => error
      compensate_failure!
      Rails.logger.error(
        "[ReceiptAnalysis] enqueue_failed run_id=#{run.id} job=#{job_class.name} error_class=#{error.class.name}"
      )
      raise EnqueueError, "analysis job enqueue failed"
    end

    private

    attr_reader :run, :job_class

    def compensate_failure!
      Tracker.new(run).fail(
        error_stage: "enqueue",
        error_code: ERROR_CODE,
        error_message: ERROR_MESSAGE
      )
    rescue TerminalRunError, ActiveRecord::RecordNotFound
      nil
    end
  end
end
