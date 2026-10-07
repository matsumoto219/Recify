module Analysis
  class ReceiptPaymentEvidenceExtractor
    MONEY_PATTERN = /[▲△\-−]?\s*[¥￥]?\s*(?:\d{1,3}(?:[,，]\d{3})+|\d+)(?:円)?/.freeze
    AMOUNT_ONLY_PATTERN = /\A\s*[▲△\-−]?\s*[¥￥]?\s*(?:\d{1,3}(?:[,，]\d{3})+|\d+)(?:円)?\s*\z/.freeze
    PARENTHESIZED_PAYMENT_CODE_PATTERN = /[（(]\s*\d{1,6}\s*[)）]/.freeze
    SUMMARY_AMOUNT_ONLY_PATTERN = /\A\s*[¥￥]?\s*(?:\d{1,3}(?:[,，]\d{3})+|\d+)(?:円)?\s*[)）]?\s*\z/.freeze
    RATE_ONLY_PATTERN = /\A\s*\d+(?:\.\d+)?\s*[%％]\s*\z/.freeze
    METADATA_VALUE_PATTERN = /\A[\sA-Za-z0-9*#().-]+\z/.freeze

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(candidates:, lines:, profile:)
      @candidates = candidates.to_h.with_indifferent_access
      @lines = Array(lines).map { |line| line.to_s.unicode_normalize(:nfkc) }
      @profile = profile
      @amount_max = ReceiptAmountService.receipt_payment_amount_max
      @consumed_line_indexes = []
      @zero_method_identities = []
      @ambiguous = false
    end

    def call
      payments = line_payments
      payments = add_card_amount_label_payment(payments)
      payments = merge_structured_payments(payments)
      payments = add_cash_settlement(payments)
      @payments = payments
      method_conflict = inspect_full_payment_collisions(payments)
      @ambiguous = true if payments.any? { |payment| payment[:amount_role] == "unknown" }
      inspect_settlement_lines
      gift_keys = payments.select { |payment| payment[:amount_role] == "voucher_tender" }
        .map { |payment| payment[:settlement_method_key] }.uniq

      {
        payments: payments,
        settlement: {
          bounded: section_start_index.present?,
          complete: section_start_index.present? && !@ambiguous && settlement_closed?,
          ambiguous: @ambiguous || section_start_index.nil?,
          observed_ambiguity: @ambiguous,
          method_conflict: method_conflict,
          zero_method_identities: @zero_method_identities.uniq,
          source_start_line_index: section_start_index,
          source_end_line_index: section_end_index,
          gift_tender_method_keys: gift_keys
        }
      }
    end

    private

    attr_reader :candidates, :lines, :profile, :amount_max

    def section_start_index
      return @section_start_index if defined?(@section_start_index)

      @section_start_index = lines.find_index do |line|
        line.match?(profile.analysis_payment_section_start_pattern) ||
          line.match?(profile.analysis_payment_section_total_pattern)
      end
    end

    def section_end_index
      return @section_end_index if defined?(@section_end_index)

      start_index = section_start_index || 0
      @section_end_index = ((start_index + 1)...lines.length).find do |index|
        lines[index].match?(profile.analysis_payment_section_end_pattern)
      end || lines.length
    end

    def in_section?(index)
      section_start_index.present? && index >= section_start_index && index < section_end_index
    end

    def settlement_closed?
      indexes = @payments.flat_map { |payment| [ payment[:method_source_line_index], payment[:source_line_index] ] }
        .compact.select { |index| in_section?(index) }
      return false if indexes.empty?
      return true if section_end_index < lines.length && indexes.max < section_end_index

      change_index = settlement_label_index(profile.analysis_cash_change_label_pattern)
      return false unless change_index && in_section?(change_index) && change_index > indexes.max

      entry = settlement_amount_entry(change_index)
      entry && in_section?(entry[:line_index])
    end

    def line_payments
      lines.each_with_index.flat_map do |line, index|
        sources = column_payment_sources(index)
        if sources
          @consumed_line_indexes |= [ index, index + 1 ]
          next sources.filter_map do |source|
            build_line_payment(source[:text], index, amount_entry: source[:amount_entry])
          end
        end

        [ build_line_payment(line, index) ].compact
      end
    end

    def build_line_payment(line, index, amount_entry: nil)
      return if section_start_index && index >= section_end_index
      if line.match?(profile.analysis_return_refund_kind_pattern)
        @ambiguous = true if in_section?(index)
        return
      end
      if line.match?(profile.analysis_point_payment_line_pattern)
        return point_payment_evidence(line, index)
      end
      return if excluded_method_line?(line)
      return if line.match?(profile.ocr_card_slip_context_pattern)
      return if index.positive? && lines[index - 1].match?(profile.analysis_fallback_payment_metadata_label_pattern)
      return unless line.match?(profile.analysis_fallback_payment_line_pattern)
      voucher = line.match?(profile.analysis_voucher_payment_pattern)
      return if voucher && section_start_index.present? && !in_section?(index)
      return if item_owned_line?(index)

      identity = method_identity(line)
      return if identity.blank?
      return unless in_section?(index) || line.match?(profile.analysis_payment_affirmative_pattern)

      amount_entry ||= amount_entry_for_line(index) unless cash_total_line?(line) && !amount_entry(line, index)
      if line.match?(profile.analysis_payment_informational_zero_pattern) && amount_entry&.fetch(:amount) == 0 && printed_receipt_total&.positive?
        @zero_method_identities << identity
        @consumed_line_indexes |= [ index, amount_entry[:line_index] ]
        return
      end
      return if voucher && !in_section?(index) && amount_entry&.fetch(:amount) == 0
      affirmative = line.match?(profile.analysis_payment_affirmative_pattern)
      @ambiguous = true if voucher && !affirmative
      method = cash_total_line?(line) ? "cash" : method_text(line, voucher: voucher)
      payment = payment_evidence(
        method: method,
        identity: identity,
        amount: amount_entry&.fetch(:amount),
        text: line,
        source_line_index: amount_entry&.fetch(:line_index) || index,
        method_line_index: index,
        voucher: voucher,
        affirmative: affirmative,
        amount_span: amount_entry&.fetch(:span)
      )
      @consumed_line_indexes |= [ index, amount_entry&.fetch(:line_index) ].compact
      payment
    end

    def point_payment_evidence(line, index)
      return unless in_section?(index)
      return if line.match?(profile.analysis_payment_sale_or_promo_pattern) || line.match?(profile.analysis_point_display_line_pattern)
      return if line.match?(/[▲△\-−]\s*[¥￥]?\s*\d/)

      source_index = index
      matches = line.to_enum(:scan, profile.analysis_explicit_payment_money_pattern).map { Regexp.last_match.dup }
      if matches.empty?
        source_index += 1
        return unless lines[source_index].to_s.match?(AMOUNT_ONLY_PATTERN)
        matches = lines[source_index].to_s.to_enum(:scan, profile.analysis_explicit_payment_money_pattern).map { Regexp.last_match.dup }
      end
      return unless matches.one?

      match = matches.first
      amount = ReceiptAmountService.parse_amount_or_nil(match.to_s)
      return unless amount && amount >= 0 && amount <= amount_max

      first_amount = line.match(profile.analysis_adjustment_amount_candidate_pattern)
      method = first_amount ? line[0...first_amount.begin(0)].strip : line.strip
      @consumed_line_indexes |= [ index, source_index ]
      token = MoneyTokenClassifier.call(
        text: lines[source_index],
        money_pattern: profile.analysis_adjustment_amount_candidate_pattern,
        profile: profile
      ).find { |candidate| candidate[:kind] == :money && candidate[:amount] == amount }
      payment_evidence(
        method: method,
        identity: "point",
        amount: amount,
        text: line,
        source_line_index: source_index,
        method_line_index: index,
        voucher: false,
        affirmative: true,
        amount_span: token ? token[:span_start]...token[:span_end] : match.begin(0)...match.end(0)
      )
    end

    def column_payment_sources(index)
      methods = lines[index].split(/[[:space:]]{2,}/).map(&:strip)
      return unless methods.size > 1 && methods.all? { |method| method.match?(profile.analysis_fallback_payment_line_pattern) }
      return unless methods.none? { |method| method.match?(MONEY_PATTERN) }

      amounts_line = lines[index + 1].to_s
      amounts = amounts_line.split(/[[:space:]]{2,}/).map(&:strip)
      return unless amounts.size == methods.size && amounts.all? { |amount| amount.match?(AMOUNT_ONLY_PATTERN) }

      position = 0
      methods.zip(amounts).map do |method, amount_text|
        offset = amounts_line.index(amount_text, position)
        position = offset + amount_text.length
        entry = amount_entry(amount_text, index + 1)
        entry[:span] = offset...(offset + amount_text.length) if entry
        { text: method, amount_entry: entry }
      end
    end

    def excluded_method_line?(line)
      exclusion_text = if line.match?(profile.analysis_voucher_payment_pattern) && line.match?(profile.analysis_payment_tender_amount_pattern)
        line.gsub(profile.analysis_cash_deposit_label_pattern, "")
      else
        line
      end
      line.match?(profile.analysis_payment_sale_or_promo_pattern) ||
        exclusion_text.match?(profile.analysis_fallback_payment_excluded_pattern) ||
        line.match?(profile.analysis_fallback_payment_metadata_label_pattern)
    end

    def item_owned_line?(index)
      return false if index.nil?

      Array(candidates[:items]).any? do |item|
        next false unless item.respond_to?(:to_h)

        normalized = item.to_h.with_indifferent_access
        Integer(normalized[:source_line_index], exception: false) == index
      end
    end

    def method_identity(text)
      return "point" if text.match?(profile.analysis_point_payment_line_pattern)
      detected = ReceiptFallbackPatterns.detect_payment_method(text, profile: profile)
      return "other" if text.match?(profile.analysis_voucher_payment_pattern)

      detected unless detected == "other"
    end

    def same_instrument?(left, right)
      identity = method_identity(left)
      return false unless identity && identity == method_identity(right)

      left_method = method_text(left, voucher: true)
      right_method = method_text(right, voucher: true)
      alias_pattern = profile.analysis_payment_category_alias_patterns[identity]
      return true if alias_pattern && (left_method.match?(alias_pattern) || right_method.match?(alias_pattern))

      left_key = instrument_key(left_method)
      right_key = instrument_key(right_method)
      left_key.present? && left_key == right_key
    end

    def instrument_key(method)
      method_key(method_text(method, voucher: true).gsub(profile.analysis_payment_instrument_qualifier_pattern, ""))
    end

    def method_text(text, voucher:)
      source = text.gsub(PARENTHESIZED_PAYMENT_CODE_PATTERN, "").gsub(MONEY_PATTERN, " ").gsub(/[¥￥]/, " ").strip
      if voucher
        source = source.gsub(profile.analysis_payment_method_suffix_pattern, " ").strip
      end
      source.gsub(/[[:space:]]+/, " ").presence || text.strip
    end

    def method_key(method)
      method.to_s.downcase.gsub(/[[:space:]:：-]+/, "")
    end

    def amount_entry_for_line(index)
      entry = amount_entry(lines[index], index)
      return entry if entry

      next_index = index + 1
      return unless next_index < section_end_index
      if lines[next_index].match?(profile.analysis_fallback_payment_amount_label_pattern) &&
          !lines[next_index].match?(profile.analysis_payment_section_total_pattern)
        entry = amount_entry(lines[next_index], next_index)
        return entry if entry
        next_index += 1
      end
      return unless next_index < section_end_index
      return unless lines[next_index].match?(AMOUNT_ONLY_PATTERN)
      return amount_entry(lines[next_index], next_index) if amount_entry(lines[next_index], next_index)&.fetch(:amount) == 0
      unless lines[next_index].match?(profile.analysis_explicit_payment_money_pattern)
        return unless in_section?(index)
        return unless (lines[index].match?(profile.analysis_fallback_payment_amount_label_pattern) &&
          lines.any? { |line| line.match?(profile.ocr_card_slip_context_pattern) }) || bare_amounts_match_printed_total?
      end

      amount_entry(lines[next_index], next_index)
    end

    def bare_amounts_match_printed_total?
      totals = lines.each_with_index.filter_map do |line, index|
        next unless line.match?(profile.analysis_payment_section_total_pattern)

        amount_entry(line, index)&.fetch(:amount) || amount_entry(lines[index + 1].to_s, index + 1)&.fetch(:amount)
      end.uniq
      return false unless totals.one?

      printed_amounts = lines.each_with_index.filter_map do |line, index|
        next if excluded_method_line?(line)
        next unless line.match?(profile.analysis_fallback_payment_line_pattern)

        amount_entry(line, index)&.fetch(:amount) ||
          (lines[index + 1].to_s.match?(AMOUNT_ONLY_PATTERN) && amount_entry(lines[index + 1], index + 1)&.fetch(:amount))
      end
      printed_amounts.present? && printed_amounts.none? { |amount| amount == false } && printed_amounts.sum == totals.first
    end

    def printed_receipt_total
      values = lines.each_with_index.filter_map do |line, index|
        next unless line.match?(profile.analysis_payment_section_total_pattern)

        amount_entry(line, index)&.fetch(:amount) || amount_entry(lines[index + 1].to_s, index + 1)&.fetch(:amount)
      end.uniq
      values.first if values.one?
    end

    def inspect_full_payment_collisions(payments)
      total = printed_receipt_total
      return false unless total&.positive?

      full_payments = payments.select { |payment| payment[:amount] == total }
      return false unless full_payments.size > 1

      @ambiguous = true
      full_payments.map { |payment| payment[:method_identity] }.compact.uniq.size > 1
    end

    def cash_total_line?(line)
      line.gsub(/[[:space:]]+/, "").match?(profile.analysis_cash_total_payment_pattern)
    end

    def settlement_amount_entry(index)
      text = lines[index].to_s
      source_index = index
      unless text.match?(profile.analysis_settlement_amount_candidate_pattern)
        source_index = ((index + 1)..[ index + 3, lines.length - 1 ].min).find do |candidate_index|
          lines[candidate_index].match?(profile.analysis_settlement_amount_candidate_pattern)
        end
        return unless source_index
        text = lines[source_index].to_s
      end
      tokens = text.scan(profile.analysis_settlement_amount_candidate_pattern)
      return unless tokens.one?

      normalized = tokens.first.gsub(/(?<=\d)\.(?=\d{3}(?:\D|\z))/, ",")
      amount = ReceiptAmountService.parse_amount_or_nil(normalized)&.abs
      return unless amount && amount <= amount_max

      { amount: amount, line_index: source_index }
    end

    def amount_entry(text, line_index)
      text = text.gsub(PARENTHESIZED_PAYMENT_CODE_PATTERN) { |match| " " * match.length }
      return if text.match?(/[¥￥]\s*\d(?:\s+\d)+/)
      return if text.match?(/[▲△\-−]\s*[¥￥]?\s*\d/)

      matches = text.to_enum(:scan, MONEY_PATTERN).map { Regexp.last_match.dup }
      return unless matches.one?

      match = matches.first
      amount = ReceiptAmountService.parse_amount_or_nil(match.to_s)
      return unless amount && amount >= 0 && amount <= amount_max

      { amount: amount, line_index: line_index, span: match.begin(0)...match.end(0) }
    end

    def add_card_amount_label_payment(payments)
      return payments if payments.any? { |payment| payment[:amount].present? || payment[:printed_amount].present? }
      return payments unless lines.any? { |line| line.match?(profile.ocr_card_slip_context_pattern) }

      method = payments.first&.fetch(:method) || candidates[:payment_method_text].presence || card_brand_method
      method = method.to_s
      identity = method_identity(method)
      return payments unless %w[credit_card debit_card].include?(identity)

      indexes = lines.each_index.select do |index|
        in_section?(index) && lines[index].match?(profile.analysis_fallback_payment_amount_label_pattern) &&
          !lines[index].match?(profile.analysis_payment_section_total_pattern)
      end
      return payments if indexes.size > 1

      index = indexes.first || section_start_index
      entry = indexes.one? ? amount_entry_for_line(index) : nil
      @consumed_line_indexes |= [ index, entry&.fetch(:line_index) ].compact
      [ payment_evidence(
        method: method,
        identity: identity,
        amount: entry&.fetch(:amount),
        text: lines[index],
        source_line_index: entry&.fetch(:line_index) || index,
        method_line_index: nil,
        voucher: false,
        affirmative: true,
        amount_span: entry&.fetch(:span)
      ) ]
    end

    def card_brand_method
      methods = lines.each_with_index.filter_map do |line, index|
        next unless index.positive? && lines[index - 1].match?(profile.analysis_fallback_payment_metadata_label_pattern)
        next unless %w[credit_card debit_card].include?(method_identity(line))

        method_text(line, voucher: false)
      end.uniq
      methods.first if methods.one?
    end

    def payment_evidence(method:, identity:, amount:, text:, source_line_index:, method_line_index:, voucher:, affirmative:, amount_span: nil)
      role = if amount.nil?
        "unknown"
      elsif voucher && !text.match?(profile.analysis_payment_applied_amount_pattern)
        "voucher_tender"
      else
        "applied"
      end
      role = "voucher_tender" if voucher && text.match?(profile.analysis_payment_tender_amount_pattern) && amount.present?

      {
        method: method,
        amount: role == "applied" ? amount : nil,
        printed_amount: amount,
        amount_role: role,
        method_identity: identity,
        settlement_method_key: method_key(method),
        settlement_use: affirmative,
        source_provider: "ocr_line",
        source_text: text,
        source_line_index: source_line_index,
        method_source_line_index: method_line_index,
        source_span_start: amount_span&.begin,
        source_span_end: amount_span&.end
      }
    end

    def merge_structured_payments(payments)
      Array(candidates[:payments]).each_with_index do |value, index|
        next unless value.respond_to?(:to_h)

        normalized = value.to_h.with_indifferent_access
        method = normalized[:method].to_s.strip
        if method.blank?
          known_source = payments.select do |payment|
            exact_amount_source?(normalized) && physical_amount_source_matches?(payment, normalized)
          end
          if known_source.one? && (normalized[:amount].nil? || valid_structured_amount(normalized[:amount]) == known_source.first[:printed_amount])
            next
          end
          @ambiguous = true if normalized[:amount].present?
          next
        end
        next if method.match?(profile.analysis_payment_sale_or_promo_pattern) || method.match?(profile.analysis_point_display_line_pattern)
        next if excluded_method_line?(method) && !method.match?(profile.analysis_point_payment_line_pattern)

        identity = method_identity(method)
        if identity.blank?
          @ambiguous = true
          next
        end
        source_index = structured_source_index(normalized)
        if method.match?(profile.analysis_payment_informational_zero_pattern) && valid_structured_amount(normalized[:amount]) == 0 && printed_receipt_total&.positive?
          @zero_method_identities << identity
          next
        end
        next if source_index && section_start_index && source_index >= section_end_index
        if normalized[:method_source_line_index].present? && source_index.nil?
          @ambiguous = true
          next
        end
        amount_source_index = Integer(normalized[:source_line_index], exception: false)
        if source_index && (lines[source_index].match?(profile.analysis_payment_sale_or_promo_pattern) ||
            lines[source_index].match?(profile.analysis_point_display_line_pattern) || item_owned_line?(source_index) || item_owned_line?(amount_source_index))
          next
        end
        matches = payments.select do |payment|
          next false if source_index.nil?

          payment[:method_source_line_index] == source_index && same_instrument?(payment[:method], method) &&
            physical_amount_source_matches?(payment, normalized)
        end
        if matches.size > 1
          @ambiguous = true
          next
        end
        matching = matches.first
        if source_index && matching.nil? && payments.any? { |payment| payment[:method_source_line_index] == source_index }
          @ambiguous = true
          next
        end
        if matching.nil?
          payments.reject! do |payment|
            payment[:method_identity] == identity && payment[:amount_role] == "unknown" &&
              !payment[:settlement_use]
          end
        end
        if matching
          if normalized[:amount].present? && matching[:printed_amount] != valid_structured_amount(normalized[:amount])
            @ambiguous = true
          end
          if identity == "cash" || instrument_key(matching[:method]) == instrument_key(method)
            matching[:method] = method
            matching[:settlement_method_key] = method_key(method)
          end
          next
        end
        voucher = method.match?(profile.analysis_voucher_payment_pattern)
        next if voucher && source_index && !in_section?(source_index) && valid_structured_amount(normalized[:amount]) == 0
        source_text = source_index.present? ? lines[source_index].to_s : normalized[:raw_text].to_s
        source_text = method if source_text.blank?
        affirmative = source_text.match?(profile.analysis_payment_affirmative_pattern)
        @ambiguous = true if voucher && (!source_index || !in_section?(source_index) || !affirmative)
        entry = payment_evidence(
          method: method_text(method, voucher: voucher),
          identity: identity,
          amount: valid_structured_amount(normalized[:amount]),
          text: source_text,
          source_line_index: Integer(normalized[:source_line_index], exception: false),
          method_line_index: source_index,
          voucher: voucher,
          affirmative: affirmative
        )
        entry.merge!(SourceEvidenceAttributeExtractor.call(normalized))
        entry[:source_provider] = normalized[:source_provider].presence || "azure_structured"
        entry[:source_field_path] ||= "documents[0].fields.Payments[#{index}].Amount"
        @consumed_line_indexes |= [ source_index, entry[:source_line_index] ].compact
        payments << entry
      end
      payments
    end

    def physical_amount_source_matches?(payment, structured)
      source_index = Integer(structured[:source_line_index], exception: false)
      return true unless source_index
      return false unless payment[:source_line_index] == source_index

      start_index = Integer(structured[:source_span_start], exception: false)
      end_index = Integer(structured[:source_span_end], exception: false)
      return true unless start_index && end_index

      actual_start = payment[:source_span_start]
      actual_end = payment[:source_span_end]
      actual_start && actual_end && start_index < actual_end && actual_start < end_index
    end

    def exact_amount_source?(value)
      index = Integer(value[:source_line_index], exception: false)
      start_index = Integer(value[:source_span_start], exception: false)
      end_index = Integer(value[:source_span_end], exception: false)
      index && start_index && end_index && index >= 0 && index < lines.length &&
        start_index >= 0 && end_index > start_index && end_index <= lines[index].length
    end

    def structured_source_index(payment)
      method_index = Integer(payment[:method_source_line_index], exception: false)
      if method_index
        return method_index if valid_method_source_index?(method_index, payment[:method], payment: payment)

        return nil
      end

      amount_index = Integer(payment[:source_line_index], exception: false)
      if valid_method_source_index?(amount_index, payment[:method])
        return amount_index
      end
      nil
    end

    def valid_method_source_index?(index, method, payment: nil)
      return false unless index && index >= 0 && index < lines.length

      text = lines[index]
      if payment
        start_index = Integer(payment[:method_source_span_start], exception: false)
        end_index = Integer(payment[:method_source_span_end], exception: false)
        if start_index && end_index
          return false unless start_index >= 0 && end_index > start_index && end_index <= text.length

          text = text[start_index...end_index]
        end
      end
      same_instrument?(text, method.to_s) &&
        (text.match?(profile.analysis_fallback_payment_line_pattern) || text.match?(profile.analysis_point_payment_line_pattern))
    end

    def valid_structured_amount(value)
      return unless value.is_a?(Numeric) || value.is_a?(String)
      return if value.respond_to?(:finite?) && !value.finite?

      amount = ReceiptAmountService.parse_amount_or_nil(value)
      amount if amount && amount >= 0 && amount <= amount_max
    end

    def add_cash_settlement(payments)
      deposit_index = settlement_label_index(profile.analysis_cash_deposit_label_pattern)
      change_index = settlement_label_index(profile.analysis_cash_change_label_pattern)
      if deposit_index && lines[deposit_index].match?(profile.analysis_voucher_payment_pattern)
        @ambiguous = true
        return payments
      end
      if deposit_index.nil? && payments.one? && payments.first[:method_identity] == "cash"
        candidate = payments.first
        index = candidate[:method_source_line_index]
        if index && in_section?(index) && !candidate[:source_text].match?(profile.analysis_payment_applied_amount_pattern)
          deposit_index = index
        end
      end
      return payments unless deposit_index && change_index

      deposit_entry = settlement_amount_entry(deposit_index)
      change_entry = settlement_amount_entry(change_index)
      deposit = deposit_entry&.fetch(:amount)
      change = change_entry&.fetch(:amount)
      @consumed_line_indexes |= (deposit_index..(deposit_entry&.fetch(:line_index) || deposit_index)).to_a +
        (change_index..(change_entry&.fetch(:line_index) || change_index)).to_a
      return payments if deposit && change && external_tax_settlement_conflict?(deposit - change)
      cash_payment = payments.find { |payment| payment[:method_identity] == "cash" && payment[:amount]&.positive? }
      if cash_payment
        valid_pair = deposit && change && deposit >= change
        if cash_payment[:amount] == deposit && !cash_payment[:source_text].match?(profile.analysis_payment_applied_amount_pattern)
          if valid_pair
            cash_payment[:amount] = deposit - change
            cash_payment[:amount_role] = "cash_settlement"
          else
            cash_payment[:amount] = nil
            cash_payment[:amount_role] = "unknown"
          end
          cash_payment[:source_span_start] = nil
          cash_payment[:source_span_end] = nil
        end
        @ambiguous = true unless valid_pair
        @ambiguous = true if payments.any? { |payment| payment[:method_identity] == "other" } && change&.positive?
        return payments
      end
      return payments if payments.any? { |payment| payment[:amount_role] == "applied" } && !lines[deposit_index].match?(profile.finalize_cash_payment_method_pattern)

      explicit_cash = lines[deposit_index].match?(profile.finalize_cash_payment_method_pattern)
      if deposit.nil? || change.nil? || deposit < change ||
          (payments.any? { |payment| payment[:method_identity] == "other" } && !explicit_cash)
        @ambiguous = true
        return payments
      end

      payments + [ payment_evidence(
        method: "cash",
        identity: "cash",
        amount: deposit - change,
        text: lines[deposit_index],
        source_line_index: deposit_index,
        method_line_index: deposit_index,
        voucher: false,
        affirmative: true
      ).merge(amount_role: "cash_settlement", printed_amount: deposit) ]
    end

    def inspect_settlement_lines
      unless section_start_index
        inspect_unbounded_payment_lines
        return
      end

      (section_start_index...section_end_index).each do |index|
        line = lines[index]
        if line.match?(profile.analysis_return_refund_kind_pattern)
          @ambiguous = true
          next
        end
        next if line.blank? || @consumed_line_indexes.include?(index)
        next if line.match?(profile.analysis_payment_section_start_pattern)
        if line.match?(profile.analysis_payment_section_total_pattern)
          entry = amount_entry_for_line(index)
          @consumed_line_indexes |= [ entry&.fetch(:line_index) ].compact
          next
        end
        if line.match?(profile.analysis_payment_informational_amount_pattern)
          entry = amount_entry_for_line(index)
          actual = @payments.select { |payment| %w[e_money qr_payment].include?(payment[:method_identity]) }
          if entry && actual.present? && actual.all? { |payment| !payment[:amount].nil? } && actual.sum { |payment| payment[:amount] } == entry[:amount]
            @consumed_line_indexes |= [ entry[:line_index] ]
            next
          end
        end
        if line.match?(profile.analysis_payment_metadata_id_title_pattern)
          @consumed_line_indexes |= [ index + 1 ] if lines[index + 1].to_s.match?(METADATA_VALUE_PATTERN)
          next
        end
        next if line.match?(profile.analysis_fallback_payment_metadata_label_pattern)
        next if index.positive? && lines[index - 1].match?(profile.analysis_fallback_payment_metadata_label_pattern) && line.match?(METADATA_VALUE_PATTERN)
        next if line.match?(profile.analysis_payment_sale_or_promo_pattern)
        next if line.match?(profile.analysis_point_display_line_pattern)
        if line.match?(profile.analysis_payment_tax_block_heading_pattern) && lines[index + 1].to_s.match?(profile.analysis_payment_tax_block_rate_pattern)
          @consumed_line_indexes |= [ index + 1 ]
          [ index + 2, index + 3 ].each do |child_index|
            break unless lines[child_index].to_s.match?(SUMMARY_AMOUNT_ONLY_PATTERN)

            @consumed_line_indexes |= [ child_index ]
          end
          next
        end
        if line.match?(profile.analysis_payment_tax_summary_pattern) && !line.match?(profile.analysis_payment_affirmative_pattern)
          child_index = index + 1
          if lines[child_index].to_s.match?(RATE_ONLY_PATTERN)
            @consumed_line_indexes |= [ child_index ]
            child_index += 1
          end
          @consumed_line_indexes |= [ child_index ] if lines[child_index].to_s.match?(SUMMARY_AMOUNT_ONLY_PATTERN)
          next
        end
        if line.match?(profile.ocr_point_usage_adjustment_label_pattern) || line.match?(profile.ocr_payment_adjustment_discount_label_pattern)
          @ambiguous = true unless adjustment_amount_present?(line)
          next
        end
        if line.match?(profile.analysis_cash_change_label_pattern)
          entry = settlement_amount_entry(index)
          @consumed_line_indexes |= [ entry&.fetch(:line_index) ].compact
          @ambiguous = true unless entry&.fetch(:amount) == 0
          next
        end

        @ambiguous = true if line.match?(MONEY_PATTERN) || line.match?(profile.analysis_return_refund_kind_pattern) ||
          line.match?(profile.analysis_payment_affirmative_pattern)
      end
    end

    def inspect_unbounded_payment_lines
      lines.each_with_index do |line, index|
        next if @consumed_line_indexes.include?(index) || item_owned_line?(index)
        next if line.match?(profile.analysis_payment_sale_or_promo_pattern)
        next if line.match?(profile.analysis_fallback_payment_amount_noise_pattern)

        transaction = line.match?(profile.analysis_fallback_payment_transaction_context_pattern) ||
          line.match?(profile.analysis_point_payment_line_pattern) || line.match?(profile.ocr_payment_adjustment_discount_label_pattern)
        @ambiguous = true if transaction && line.match?(MONEY_PATTERN)
      end
    end

    def settlement_label_index(pattern)
      lines.each_index.find do |index|
        lines[index].match?(pattern) ||
          (!lines[index].match?(MONEY_PATTERN) && lines[index, 2].join.match?(pattern))
      end
    end

    def external_tax_settlement_conflict?(amount)
      details = Array(candidates[:tax_details]).filter_map do |detail|
        next unless detail.respond_to?(:to_h)

        normalized = detail.to_h.with_indifferent_access
        next unless normalized[:description].to_s.match?(profile.analysis_external_tax_description_pattern)

        net = ReceiptAmountService.parse_amount_or_nil(normalized[:net_amount])
        tax = ReceiptAmountService.parse_amount_or_nil(normalized[:amount])
        [ net, tax ] if net && tax
      end
      details.present? && details.sum(&:first) == amount && details.sum(&:last).positive?
    end

    def adjustment_amount_present?(line)
      matches = line.scan(MONEY_PATTERN)
      return false unless matches.one?

      amount = ReceiptAmountService.parse_amount_or_nil(matches.first)
      amount.present? && amount.abs <= amount_max
    end
  end
end
