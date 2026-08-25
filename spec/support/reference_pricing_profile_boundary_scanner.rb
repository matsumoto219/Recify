require "pathname"
require "prism"

module ReferencePricingProfileBoundary
  TARGET_GLOBS = %w[
    app/services/ocr/response_parser/item_calculation_mode_candidate_extractor.rb
    app/services/ocr/response_parser/reference_pricing*_extractor.rb
  ].freeze
  JAPANESE_SCRIPT_PATTERN = /[\p{Hiragana}\p{Katakana}\p{Han}]/u.freeze
  UNICODE_ESCAPE_PATTERN = /\\u(?:\{(?<braced>[0-9a-f]+(?:[ \t]+[0-9a-f]+)*)\}|(?<fixed>[0-9a-f]{4}))/i.freeze
  UNICODE_PROPERTY_PATTERN = /\\[pP]\{\^?(?<property>[^}]+)\}/.freeze
  LANGUAGE_INDEPENDENT_UNICODE_PROPERTIES = %w[
    Bidi_Control L Letter Ll Lowercase_Letter Lm Modifier_Letter Lo Other_Letter Lt Titlecase_Letter Lu Uppercase_Letter
    M Mark Mc Spacing_Mark Me Enclosing_Mark Mn Nonspacing_Mark
    N Number Nd Decimal_Number Nl Letter_Number No Other_Number
    P Punctuation Pc Connector_Punctuation Pd Dash_Punctuation Pe Close_Punctuation Pf Final_Punctuation
    Pi Initial_Punctuation Po Other_Punctuation Ps Open_Punctuation
    Z Separator Zl Line_Separator Zp Paragraph_Separator Zs Space_Separator
  ].freeze
  COUNTRY_SEMANTIC_TEXT_PATTERN = %r{
    (?<![A-Za-z_])
    (?:
      approx(?:imately)?|about|at(?:\\s\+|\s+)least|at(?:\\s\+|\s+)most|
      cancel|coupon|discounted?|estimated?|exempt|gross(?:\\s\+|\s+weight)?|not|off|
      provisional|refund|return|subtotal|tare|taxfree|tentative|total|
      up(?:\\s\+|\s+)to|void
    )
    (?![A-Za-z_])
  }ix.freeze
  ALLOWED_SHARED_CURRENCY_TEXT = "円".freeze
  PROVIDER_STRUCTURAL_TEXTS = %w[Total TotalPrice].freeze
  JAPAN_PROFILE_CONSTANT = "ReceiptAnalysisProfiles::Japan".freeze
  JAPAN_PROFILE_CODE = "JPN".freeze

  Violation = Data.define(:source_path, :line, :kind, :source)
  Issue = Data.define(:source_path, :line, :message)

  class SourceAnalyzer
    attr_reader :violations, :issues

    def initialize(source_path:)
      @source_path = source_path
      @violations = []
      @issues = []
    end

    def analyze(source)
      result = Prism.parse(source)
      unless result.success?
        result.errors.each do |error|
          issues << Issue.new(
            source_path: source_path,
            line: error.location.start_line,
            message: error.message
          )
        end
        return self
      end

      walk(result.value)
      self
    end

    private

    attr_reader :source_path

    def walk(node)
      return if node.nil?

      record_literal(node)
      record_country_profile_reference(node)
      record_country_profile_lookup(node)
      node.compact_child_nodes.each { |child| walk(child) }
    end

    def record_literal(node)
      return unless node.is_a?(Prism::StringNode) || node.is_a?(Prism::RegularExpressionNode)

      text = literal_text(node)
      return if PROVIDER_STRUCTURAL_TEXTS.include?(text)

      inspected = text.delete(ALLOWED_SHARED_CURRENCY_TEXT)
      return unless inspected.match?(JAPANESE_SCRIPT_PATTERN) ||
        country_specific_unicode_property?(inspected) ||
        inspected.match?(COUNTRY_SEMANTIC_TEXT_PATTERN)

      violations << Violation.new(
        source_path: source_path,
        line: node.location.start_line,
        kind: :country_specific_literal,
        source: node.location.slice
      )
    end

    def record_country_profile_reference(node)
      return unless node.is_a?(Prism::ConstantPathNode)

      constant_name = node.full_name.to_s.delete_prefix("::")
      return unless constant_name == JAPAN_PROFILE_CONSTANT

      violations << Violation.new(
        source_path: source_path,
        line: node.location.start_line,
        kind: :direct_country_profile_reference,
        source: node.location.slice
      )
    rescue Prism::DynamicPartsInConstantPathError
      nil
    end

    def record_country_profile_lookup(node)
      return unless node.is_a?(Prism::CallNode) && node.name == :fetch
      return unless constant_name(node.receiver) == "ReceiptAnalysisProfiles"

      arguments = node.arguments&.arguments
      return unless arguments&.one?

      country_code = arguments.first
      return unless country_code.is_a?(Prism::StringNode) && country_code.unescaped == JAPAN_PROFILE_CODE

      violations << Violation.new(
        source_path: source_path,
        line: node.location.start_line,
        kind: :direct_country_profile_lookup,
        source: node.location.slice
      )
    end

    def literal_text(node)
      text = node.unescaped
      return text unless node.is_a?(Prism::RegularExpressionNode)

      text.gsub(UNICODE_ESCAPE_PATTERN) do |escape|
        match = Regexp.last_match
        codepoints = (match[:braced] || match[:fixed]).split.map { |value| Integer(value, 16) }
        codepoints.pack("U*")
      rescue ArgumentError, RangeError
        escape
      end
    end

    def country_specific_unicode_property?(text)
      text.scan(UNICODE_PROPERTY_PATTERN).flatten.any? do |property|
        !LANGUAGE_INDEPENDENT_UNICODE_PROPERTIES.include?(property)
      end
    end

    def constant_name(node)
      case node
      when Prism::ConstantReadNode
        node.name.to_s
      when Prism::ConstantPathNode
        node.full_name.to_s.delete_prefix("::")
      end
    rescue Prism::DynamicPartsInConstantPathError
      nil
    end
  end

  class Scanner
    attr_reader :violations, :issues, :scanned_paths

    def initialize(root:, target_globs: TARGET_GLOBS)
      @root = Pathname(root)
      @target_globs = target_globs
      @violations = []
      @issues = []
      @scanned_paths = []
      scan
    end

    private

    attr_reader :root, :target_globs

    def scan
      paths = target_paths
      if paths.empty?
        issues << Issue.new(
          source_path: target_globs.join(", "),
          line: 0,
          message: "no reference pricing extractor targets found"
        )
        return
      end

      paths.each do |path|
        relative_path = path.relative_path_from(root).to_s
        scanned_paths << relative_path
        analyzer = SourceAnalyzer.new(source_path: relative_path).analyze(path.read)
        violations.concat(analyzer.violations)
        issues.concat(analyzer.issues)
      end
      violations.uniq!
    end

    def target_paths
      target_globs.flat_map { |glob| root.glob(glob) }.select(&:file?).uniq.sort
    end
  end
end
