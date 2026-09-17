module Admin
  class RunAmountInspectorPresenter < CurrentAmountInspectorPresenter
    attr_reader :snapshot

    def initialize(value)
      @snapshot = Receipts::Processing.amount_calculation_run_snapshot(value)
      unless snapshot && %w[available partial].include?(snapshot["state"])
        super(nil)
        @state = :unavailable
        return
      end

      engine = snapshot.fetch("engine")
      review_fields = engine.fetch("review").slice(
        "warnings", "mismatch_codes", "blocking_mismatch_codes", "warning_mismatch_codes",
        "selected_candidate_status", "safe_to_auto_complete"
      )
      profile = engine.except("review").merge(review_fields).merge("schema_version" => 1)
      candidate_engine = profile.fetch("amount_engine").dup
      candidate_engine["candidates"] = candidate_engine.fetch("candidates").map do |candidate|
        candidate["selected_candidate_ref"] ? candidate_engine.fetch("selected_candidate") : candidate
      end
      profile["amount_engine"] = candidate_engine
      super(profile)
      @data["computed"] = engine.fetch("computed")
      @data["resolved"] = engine.fetch("resolved")
      @data["amount_engine"]["candidates"] = candidate_engine.fetch("candidates").map do |candidate|
        if candidate["candidate_id"] == selected_candidate["candidate_id"]
          selected_candidate
        else
          sanitize_candidate(candidate, detailed: true)
        end
      end
      @saved_profile = snapshot.fetch("saved_profile").dup
      if @saved_profile.dig("profile", "item_amount_basis_assignments")
        @saved_profile["profile"] = @saved_profile.fetch("profile").dup
        @saved_profile["profile"]["item_amount_basis_assignments"] = records(
          @saved_profile["profile"]["item_amount_basis_assignments"]
        ) { |entry| entry }
      end
    end

    def review
      snapshot&.dig("engine", "review") || {}
    end

    def saved_profile
      @saved_profile || {}
    end

    def receipt_summary
      snapshot&.fetch("receipt_summary", {}) || {}
    end

    def limits
      snapshot&.fetch("limits", nil) || {}
    end

    def omissions
      snapshot&.fetch("omissions", []) || []
    end

    def partial?
      snapshot&.fetch("state") == "partial"
    end

    def omission_label(path)
      if (match = /\Acandidates\[([0-9]+)\]\.(evidence|computed_items)\z/.match(path))
        I18n.t("admin.run_amount_inspector.paths.comparison_#{match[2]}", number: match[1].to_i + 1)
      else
        I18n.t("admin.run_amount_inspector.paths.#{path.tr('.', '_')}")
      end
    end

    def limit_rows
      limits.map { |key, field| [ I18n.t("admin.run_amount_inspector.limits.#{key}"), field ] }
    end

    def receipt_rows
      status = receipt_summary["status"]
      rows(receipt_summary.except("status")) + [
        [ I18n.t("admin.run_amount_inspector.receipt_status"), status ? I18n.t("admin.run_amount_inspector.statuses.#{status}") : value(nil) ]
      ]
    end

    def rows(fields)
      result = super(fields.except("snapshot_index"))
      if fields.key?("snapshot_index")
        result << [ I18n.t("admin.run_amount_inspector.snapshot_index"), fields["snapshot_index"] ]
      end
      result
    end

    private

    def scalar_fields(input, keys)
      super(input, keys + [ "snapshot_index" ])
    end
  end
end
