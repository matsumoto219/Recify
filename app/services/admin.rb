module Admin
  class << self
    def receipt_analysis_runs(**filters)
      ReceiptAnalysisRunsQuery.call(**filters)
    end
  end
end
