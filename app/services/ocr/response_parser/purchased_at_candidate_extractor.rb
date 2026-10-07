class Ocr::ResponseParser::PurchasedAtCandidateExtractor
  MAX_PAGES = 100
  MAX_LINES = 10_000
  EXCLUDED_ROLES = %w[service_start service_end duration reference].freeze

  def self.call(...)
    extract(...).fetch(:purchased_at_text)
  end

  def self.extract(...)
    new(...).call
  end

  def initialize(fields:, lines:, profile:, analyze_result: nil)
    @fields = fields
    @lines = lines
    @profile = profile
    @analyze_result = analyze_result || {}
  end

  def call
    entries = provider_entries
    evidence = if entries
      @line_sources = associated_sources(entries)
      Analysis.purchased_at_evidence_from_lines(
        lines: entries.map { |entry| entry[:text] }, profile:, line_sources: @line_sources
      )
    elsif analyze_result["pages"].present?
      Analysis.purchased_at_evidence({})
    else
      Analysis.purchased_at_evidence_from_lines(lines:, profile:)
    end
    evidence = append_structured_candidate(evidence, entries)

    { purchased_at_text: selected_text(evidence), purchased_at_evidence: evidence }
  end

  private

  attr_reader :fields, :lines, :profile, :analyze_result

  def provider_entries
    pages = analyze_result["pages"]
    return unless pages.is_a?(Array) && pages.any? && pages.size <= MAX_PAGES

    entries = []
    pages.each_with_index do |page, page_index|
      return unless page.is_a?(Hash) && page["lines"].is_a?(Array)
      return if entries.size + page["lines"].size > MAX_LINES

      page["lines"].each_with_index do |line, line_index|
        return unless line.is_a?(Hash) && line["content"].is_a?(String)

        text = line["content"]
        return unless text.valid_encoding? && (text.encoding == Encoding::UTF_8 || text.ascii_only?)
        return if text.bytesize > 10_000 || text.match?(/[\u0000-\u001F\u007F]/)
        source = {
          candidate_id: "datetime_page_#{page_index}_line_#{line_index}",
          source_path: "pages[#{page_index}].lines[#{line_index}]", page_index:,
          association: "unlabeled"
        }.merge(span_evidence(line, text))
        box = polygon_bounds(line["polygon"])
        source[:association] = "invalid" if line.key?("polygon") && box.nil?
        source[:association] = "invalid" if analyze_result.key?("stringIndexType") && index_mapper.nil?
        entries << { text:, source:, box:, index: entries.size }
      end
    end
    return if entries.sum { |entry| entry[:text].bytesize } > Ocr::ResponseParser::AzureStringIndexMapper::MAX_CONTENT_BYTES

    entries.select { |entry| entry[:source][:span] }.sort_by { |entry| entry[:source][:span][:offset] }
      .each_cons(2) do |first, second|
        span = first[:source][:span]
        next unless span[:offset] + span[:length] > second[:source][:span][:offset]

        first[:source][:association] = "invalid"
        second[:source][:association] = "invalid"
      end
    entries
  end

  def span_evidence(line, text)
    return {} unless line.key?("spans")

    spans = line["spans"]
    return { association: "invalid" } unless spans.is_a?(Array) && spans.one? && spans.first.is_a?(Hash)
    span = spans.first.slice("offset", "length").transform_keys(&:to_sym)
    return { association: "invalid" } unless span.keys.sort == %i[length offset]
    return { association: "invalid" } unless bounded_span?(span)
    return {} if analyze_result["stringIndexType"].nil?
    return { association: "invalid" } unless index_mapper && provider_content
    return { association: "invalid" } unless index_mapper.slice(provider_content, **span) == text

    { span:, string_index_type: index_mapper.index_type }
  end

  def bounded_span?(span)
    offset = span[:offset]
    length = span[:length]
    maximum = Ocr::ResponseParser::AzureStringIndexMapper::MAX_PROVIDER_INDEX
    offset.is_a?(Integer) && offset.between?(0, maximum) && length.is_a?(Integer) &&
      length.positive? && length <= maximum - offset
  end

  def index_mapper
    return @index_mapper if defined?(@index_mapper)

    @index_mapper = Ocr::ResponseParser::AzureStringIndexMapper.build(index_type: analyze_result["stringIndexType"])
  end

  def provider_content
    return @provider_content if defined?(@provider_content)

    value = analyze_result["content"]
    @provider_content = value.dup.freeze if value.is_a?(String) && value.bytesize <= Ocr::ResponseParser::AzureStringIndexMapper::MAX_CONTENT_BYTES
  end

  def polygon_bounds(value)
    return unless value.is_a?(Array) && value.size == 8
    return unless value.all? { |coordinate| coordinate.is_a?(Numeric) && coordinate.finite? && coordinate.between?(0, 10_000) }

    xs = value.each_slice(2).map(&:first)
    ys = value.each_slice(2).map(&:last)
    return unless xs.max > xs.min && ys.max > ys.min

    { left: xs.min, right: xs.max, top: ys.min, bottom: ys.max }
  end

  def associated_sources(entries)
    labels = entries.filter_map do |entry|
      next unless label_only?(entry[:text])

      entry.merge(role: role_for(entry[:text]))
    end
    return entries.map { |entry| entry[:source].merge(association: "invalid") } if labels.size > 100

    association_count = 0
    entries.map do |entry|
      source = entry[:source].merge(join_next: next_line_same_block?(entry, entries[entry[:index] + 1]))
      next source if source[:association] == "invalid" || role_for(entry[:text]) != "unknown"
      next source unless profile.ocr_purchased_at_date_patterns.any? { |pattern| entry[:text].match?(pattern) } ||
        entry[:text].match?(profile.ocr_purchased_at_time_pattern)
      association_count += 1
      next source.merge(association: "invalid") if association_count > 50

      matching = labels.select { |label| associated_label?(label, entry, entries) }
      if matching.one?
        label = matching.first
        source.merge(label_role: label[:role], label_path: label[:source][:source_path], association: "exact")
      elsif matching.any?
        source.merge(association: "invalid")
      elsif labels.any? { |label| label[:source][:page_index] == source[:page_index] && (label[:index] - entry[:index]).abs <= 2 }
        source.merge(association: "invalid")
      else
        source
      end
    end
  end

  def next_line_same_block?(entry, following)
    return false unless following && entry[:source][:page_index] == following[:source][:page_index]
    return true if entry[:box].nil? && following[:box].nil?
    return false unless entry[:box] && following[:box]

    first = entry[:box]
    second = following[:box]
    height = [ first[:bottom] - first[:top], second[:bottom] - second[:top] ].max
    overlap = [ first[:right], second[:right] ].min - [ first[:left], second[:left] ].max
    overlap.positive? && first[:bottom] <= second[:top] && second[:top] - first[:bottom] <= height * 2
  end

  def role_for(text)
    return "unknown" unless text.is_a?(String) && text.valid_encoding?

    roles = profile.ocr_purchased_at_role_patterns.filter_map { |role, pattern| role if text.match?(pattern) }
    return "reference" if roles.include?("reference")
    return "duration" if roles.include?("duration")

    roles.one? ? roles.first : "unknown"
  end

  def label_only?(text)
    return false unless role_for(text) != "unknown"
    return false if profile.ocr_purchased_at_date_patterns.any? { |pattern| text.match?(pattern) }

    !text.match?(profile.ocr_purchased_at_time_pattern)
  end

  def associated_label?(label, entry, entries)
    return false unless label[:source][:page_index] == entry[:source][:page_index]
    return false if label[:source][:association] == "invalid"

    label_box = label[:box]
    value_box = entry[:box]
    if label_box && value_box
      height = [ label_box[:bottom] - label_box[:top], value_box[:bottom] - value_box[:top] ].max
      vertical_overlap = [ label_box[:bottom], value_box[:bottom] ].min - [ label_box[:top], value_box[:top] ].max
      horizontal_overlap = [ label_box[:right], value_box[:right] ].min - [ label_box[:left], value_box[:left] ].max
      same_row = vertical_overlap.fdiv(height) >= Rational(1, 2) && label_box[:right] <= value_box[:left]
      next_row = label_box[:bottom] <= value_box[:top] && value_box[:top] - label_box[:bottom] <= height * 2 &&
        horizontal_overlap.positive?
      return false unless same_row || next_row
      return false if entries.any? { |other| between_in_column?(other, label, entry) }

      true
    else
      label[:index] + 1 == entry[:index] && label[:box].nil? && entry[:box].nil?
    end
  end

  def between_in_column?(other, label, entry)
    return false if other[:source][:source_path] == label[:source][:source_path] || other.equal?(entry)
    return false unless other[:box] && other[:source][:page_index] == entry[:source][:page_index]

    box = other[:box]
    label_box = label[:box]
    value_box = entry[:box]
    row_overlap = [ box[:bottom], label_box[:bottom], value_box[:bottom] ].min -
      [ box[:top], label_box[:top], value_box[:top] ].max
    return true if row_overlap.positive? && box[:left] >= label_box[:right] && box[:right] <= value_box[:left]

    box[:top] > label_box[:bottom] && box[:bottom] < value_box[:top] &&
      box[:left] < value_box[:right] && box[:right] > value_box[:left]
  end

  def append_structured_candidate(evidence, entries)
    return evidence if evidence[:invalid]
    return Analysis.purchased_at_evidence({}) unless fields.is_a?(Hash)

    date_field = fields["TransactionDate"]
    time_field = fields["TransactionTime"]
    return Analysis.purchased_at_evidence({}) unless [ date_field, time_field ].all? { |field| field.nil? || field.is_a?(Hash) }
    date = date_field["valueDate"] if date_field.is_a?(Hash)
    time = time_field["valueTime"] if time_field.is_a?(Hash)
    date = date.presence
    time = time.presence
    return evidence unless date.present? || time.present?

    date = date.tr("/", "-") if date.is_a?(String)
    values = { date:, time: }.compact
    existing = evidence[:candidates]
    matching = existing.select do |candidate|
      values.all? { |key, value| comparable_value(candidate[key]) == comparable_value(value) }
    end
    return evidence if matching.any?
    return evidence if existing.any? { |candidate| candidate[:role] != "unknown" }

    source = { candidate_id: "datetime_structured_0", source_path: "fields.TransactionDate", role: "unknown", association: "unlabeled" }
    source[:source_path] = "fields.TransactionTime" unless date
    precision = date && time ? "datetime" : (date ? "date_only" : "time_only")
    candidate = source.merge(values).merge(precision:)
    if entries && [ date_field, time_field ].compact.any? { |field| field.key?("spans") }
      valid_fields = [ date_field, time_field ].compact.all? do |field|
        !field.key?("spans") || field_span_supported?(field, entries)
      end
      candidate[:association] = "invalid" unless valid_fields
      owners = [ date_field, time_field ].compact.flat_map { |field| field_source_owners(field, entries) }.uniq
      if owners.one? || same_structured_event?(owners)
        owner = owners.first
        metadata = @line_sources.fetch(owner[:index])
        roles = owners.map do |source_owner|
          role = role_for(source_owner[:text])
          role == "unknown" ? @line_sources.fetch(source_owner[:index])[:label_role] || role : role
        end.reject { |role| role == "unknown" }.uniq
        role = roles.one? ? roles.first : "unknown"
        candidate[:association] = "invalid" if roles.size > 1
        candidate[:role] = role
        candidate[:association] = metadata[:association] if metadata[:association] == "invalid"
        candidate[:association] = "exact" if role != "unknown" && candidate[:association] != "invalid"
        candidate.merge!(metadata.slice(:page_index, :label_path))
      elsif owners.size > 1
        candidate[:association] = "invalid"
      end
    elsif existing.empty? && lines.any? { |line| role_for(line) != "unknown" }
      candidate[:association] = "invalid"
    end
    Analysis.purchased_at_evidence(evidence.merge(candidates: existing + [ candidate ], complete: evidence[:complete] && candidate[:association] != "invalid"))
  end

  def field_source_owners(field, entries)
    return [] unless field.is_a?(Hash) && field["spans"].is_a?(Array) && field["spans"].one?

    span = field["spans"].first
    return [] unless span.is_a?(Hash) && span["offset"].is_a?(Integer) && span["length"].is_a?(Integer)

    entries.select do |entry|
      parent = entry[:source][:span]
      parent && parent[:offset] < span["offset"] + span["length"] && parent[:offset] + parent[:length] > span["offset"]
    end
  end

  def same_structured_event?(owners)
    return false unless owners.size.between?(2, 3) && owners.all? { |owner| owner[:box] }
    return false unless owners.map { |owner| owner[:source][:page_index] }.uniq.one?
    return false unless owners.map { |owner| @line_sources.fetch(owner[:index])[:label_path] }.compact.uniq.size <= 1

    ordered = owners.sort_by { |owner| owner[:index] }
    return false unless ordered.each_cons(2).all? { |first, second| first[:index] + 1 == second[:index] }

    ordered.each_cons(2).all? do |first, second|
      left = first[:box]
      right = second[:box]
      height = [ left[:bottom] - left[:top], right[:bottom] - right[:top] ].max
      overlap = [ left[:bottom], right[:bottom] ].min - [ left[:top], right[:top] ].max
      same_row = overlap.fdiv(height) >= Rational(1, 2) && left[:right] <= right[:left]
      same_row || next_line_same_block?(first, second)
    end
  end

  def field_span_supported?(field, entries)
    spans = field["spans"]
    return false unless spans.is_a?(Array) && spans.one? && spans.first.is_a?(Hash) && index_mapper && provider_content

    span = spans.first.slice("offset", "length").transform_keys(&:to_sym)
    return false unless span.keys.sort == %i[length offset] && bounded_span?(span)

    text = index_mapper.slice(provider_content, **span)
    return false unless text.present?
    parsed = Analysis.purchased_at_evidence_from_lines(lines: [ text.delete("\r\n") ], profile:)[:candidates]
    return false unless parsed.one?
    if field.key?("valueDate")
      return false unless parsed.first[:date] == field["valueDate"]
    elsif field.key?("valueTime")
      return false unless comparable_value(parsed.first[:time]) == comparable_value(field["valueTime"])
    end

    owners = field_source_owners(field, entries)
    return false if owners.empty?

    cursor = span[:offset]
    ending = span[:offset] + span[:length]
    owners.sort_by { |entry| entry[:source][:span][:offset] }.each do |entry|
      parent = entry[:source][:span]
      if parent[:offset] > cursor
        gap = index_mapper.slice(provider_content, offset: cursor, length: parent[:offset] - cursor)
        return false unless gap&.match?(/\A[[:space:]]*\z/)
      end
      cursor = [ ending, parent[:offset] + parent[:length] ].min
    end
    cursor == ending
  end

  def comparable_value(value)
    value.is_a?(String) ? value.sub(/\A(\d{2}:\d{2}):00\z/, '\\1') : value
  end

  def selected_text(evidence)
    return unless evidence[:complete] && !evidence[:invalid]

    candidates = evidence[:candidates].reject { |candidate| EXCLUDED_ROLES.include?(candidate[:role]) || candidate[:association] == "invalid" }
    primary = candidates.select { |candidate| %w[transaction settlement].include?(candidate[:role]) }
    candidates = primary if primary.any?
    if primary.empty?
      issuance = candidates.select { |candidate| candidate[:role] == "issuance" }
      candidates = issuance if issuance.any?
    end
    dated = candidates.select { |candidate| candidate[:date] }
    candidates = dated if dated.any?
    return unless candidates.one?

    [ candidates.first[:date], candidates.first[:time] ].compact.join(" ")
  end
end
