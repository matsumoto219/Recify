require 'rails_helper'

RSpec.describe 'Service layer child implementation boundary' do
  SERVICE_LAYER_TARGET_GLOBS = %w[
    app/controllers/**/*.rb
    app/jobs/**/*.rb
    app/models/**/*.rb
    app/helpers/**/*.rb
    app/presenters/**/*.rb
    app/services/**/*.rb
  ].freeze

  SERVICE_LAYER_RULES = [
    {
      name: 'AI',
      child_reference: /\bAi::[A-Z][A-Za-z0-9_:]*/,
      parent_paths: %w[app/services/receipt_ai_enrichment_service.rb],
      internal_globs: %w[app/services/ai/**/*.rb]
    },
    {
      name: 'OCR',
      child_reference: /\bOcr::(?:AvailabilityChecker|Client|ResponseParser|ResultTemplate)\b/,
      parent_paths: %w[app/services/receipt_ocr_service.rb],
      internal_globs: %w[app/services/ocr/**/*.rb]
    },
    {
      name: 'Analysis',
      child_reference: /\bAnalysis::(?:MoneyTokenClassifier|ReceiptBuildParamsService|ReceiptProcessingErrorMapper|ReceiptFallbackPatterns|ReceiptSignalEvaluator|ReceiptItemNormalizer|RetryService|SourceEvidenceIndex|StoreNameCandidateClassifier)\b/,
      parent_paths: %w[app/services/analysis.rb],
      internal_globs: %w[app/services/analysis/**/*.rb]
    },
    {
      name: 'ReceiptAnalysisPipeline',
      child_reference: /\bReceiptAnalysisPipeline::(?:OcrStep|AiStep|FinalizeStep|FinalizeDecision|Config|Result)\b/,
      parent_paths: %w[app/services/receipt_analysis_pipeline.rb],
      internal_globs: %w[app/services/receipt_analysis_pipeline/**/*.rb]
    },
    {
      name: 'ExternalServices',
      child_reference: /\bExternalServices::(?:StatusStore|StatusSnapshot|ErrorDetail|DebugStateSwitcher)\b/,
      parent_paths: %w[app/services/external_services.rb],
      internal_globs: %w[app/services/external_services/**/*.rb]
    },
    {
      name: 'SecurityEvents',
      child_reference: /\bSecurityEvents::(?:Detector|DetectionCandidate|UrlFieldPolicy|MetadataSanitizer|RetentionCleanup|Recorder|Rules::[A-Z][A-Za-z0-9_]*)\b/,
      parent_paths: %w[app/services/security_events.rb],
      internal_globs: %w[app/services/security_events/**/*.rb]
    },
    {
      name: 'Usage',
      child_reference: /\bUsage::(?:Counters|Limits)\b/,
      parent_paths: %w[app/services/usage.rb],
      internal_globs: %w[app/services/usage/**/*.rb]
    }
  ].freeze

  it '親facadeと同一namespace内部以外から子実装を直接呼ばない' do
    violations = SERVICE_LAYER_RULES.flat_map do |rule|
      scanned_files_for(rule).flat_map do |path|
        path.readlines.filter_map.with_index(1) do |line, line_number|
          code = line.sub(/#.*/, '')
          next unless code.match?(rule[:child_reference])

          "#{rule[:name]} #{relative_path(path)}:#{line_number}: #{line.strip}"
        end
      end
    end

    expect(violations).to be_empty, violations.join("\n")
  end

  def scanned_files_for(rule)
    target_files.reject { |path| allowed_path?(path, rule) }
  end

  def target_files
    SERVICE_LAYER_TARGET_GLOBS.flat_map { |pattern| Rails.root.glob(pattern) }.uniq.sort
  end

  def allowed_path?(path, rule)
    relative = relative_path(path).to_s
    rule[:parent_paths].include?(relative) ||
      rule[:internal_globs].any? { |pattern| File.fnmatch?(pattern, relative, File::FNM_PATHNAME) }
  end

  def relative_path(path)
    path.relative_path_from(Rails.root)
  end
end
