module Analysis
  class << self
    def build_receipt_params(...)
      ReceiptBuildParamsService.call(...)
    end

    def processing_error_mapping(error_code)
      ReceiptProcessingErrorMapper.map(error_code)
    end

    def processing_error_category(error_code)
      processing_error_mapping(error_code)[:error_category]&.to_sym
    end

    def detect_category(text)
      ReceiptFallbackPatterns.detect_category(text)
    end

    def evaluate_receipt_signal(...)
      ReceiptSignalEvaluator.call(...)
    end

    def normalize_receipt_items(...)
      ReceiptItemNormalizer.normalize_ai_items(...)
    end

    def tax_detail_line_evidence(...)
      TaxDetailLineEvidenceExtractor.call(...)
    end

    def money_token_matches(...)
      MoneyTokenClassifier.money_matches(...)
    end

    def source_evidence_index(...)
      SourceEvidenceIndex.call(...)
    end

    def resolve_receipt_fact_ownership(...)
      ReceiptFactOwnershipResolver.call(...)
    end

    def enforce_ownership_consistency(params:)
      OwnershipConsistencyGuard.call(params: params)
    end

    def ownership_review_reason_resolved?(params:, reason:)
      OwnershipConsistencyGuard.review_reason_resolved?(params: params, reason: reason)
    end

    def receipt_item_ai_allowed_keys
      ReceiptItemNormalizer::AI_ALLOWED_KEYS
    end

    def retry_receipt_analysis(...)
      SystemOperations.execute_receipt_analysis_retry(...)
    end

    def retry_eligibility(...)
      SystemOperations.receipt_analysis_retry_eligibility(...)
    end

    def retry_types
      SystemOperations.receipt_analysis_retry_types
    end

    def retry_confirmation_text
      SystemOperations.receipt_analysis_retry_confirmation_text
    end

    def store_name_customer_facing_heading_candidates(...)
      StoreNameCandidateClassifier.customer_facing_heading_candidates(...)
    end

    def store_name_operator_candidates(...)
      StoreNameCandidateClassifier.operator_candidates(...)
    end

    def store_name_brand_candidate_from_legal_entity(...)
      StoreNameCandidateClassifier.brand_candidate_from_legal_entity(...)
    end

    def store_name_legal_entity_name?(...)
      StoreNameCandidateClassifier.legal_entity_name?(...)
    end

    def store_name_operator_context_line?(...)
      StoreNameCandidateClassifier.operator_context_line?(...)
    end

    def store_name_descriptive_heading_line?(...)
      StoreNameCandidateClassifier.descriptive_heading_line?(...)
    end

    def store_name_message_line?(...)
      StoreNameCandidateClassifier.store_message_line?(...)
    end

    def store_name_isolated_logo_fragment?(...)
      StoreNameCandidateClassifier.isolated_logo_fragment?(...)
    end

    def store_name_operator_legal_entity_candidate?(...)
      StoreNameCandidateClassifier.operator_legal_entity_candidate?(...)
    end

    def normalize_store_name_candidate(...)
      StoreNameCandidateClassifier.normalize_name(...)
    end

    def normalize_compact_store_name_candidate(...)
      StoreNameCandidateClassifier.normalize_compact_name(...)
    end

    def store_name_latin_logo_prefix_duplicate?(...)
      StoreNameCandidateClassifier.latin_logo_prefix_duplicate?(...)
    end

    def store_name_candidate_valid?(...)
      StoreNameCandidateClassifier.valid_candidate?(...)
    end
  end
end
