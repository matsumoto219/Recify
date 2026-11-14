module Analysis
  class StoreNameRelations
    SCHEMA_VERSION = "store_name_options_v2"
    MAX_OPTIONS = StoreNameEvidence::MAX_CANDIDATES
    MAX_NAME_LENGTH = 100

    def self.call(options:, evidence:, profile:, truncated:, invalid:)
      new(options:, evidence:, profile:, truncated:, invalid:).call
    end

    def initialize(options:, evidence:, profile:, truncated:, invalid:)
      @options = options
      @evidence = evidence.index_by { |entry| entry[:candidate_id] }
      @profile = profile
      @truncated = truncated
      @invalid = invalid
      @components = {}
      @standalone_components = {}
      @participation = {}
      @variants = {}
      @pairs = {}
    end

    def call
      return envelope([], [], invalid: true) if invalid || options.size > MAX_OPTIONS

      entries = options.uniq.flat_map do |option|
        block = composable_block(option)
        if block
          compose(option, block)
        else
          components[option[:option_id]] = component_ids(option)
          participation[option[:option_id]] = component_ids(option, require_coverage: false)
          standalone_components[option[:option_id]] = standalone_component(option)
          [ option.except(:display_components) ]
        end
      end
      entries, aliases = deduplicate(entries)
      return envelope([], [], invalid: true) if entries.size > MAX_OPTIONS || pairs.size > MAX_OPTIONS

      relations = build_relations(entries, aliases)
      entries = entries.reject { |option| unclassified_composition?(option, relations) }
      relations = build_relations(entries, aliases)
      return envelope([], [], invalid: true) if relations.any? do |relation|
        relation[:same_name_option_ids].empty? && relation[:store_location_option_ids].empty?
      end

      envelope(entries, relations, invalid: false)
    end

    private

    attr_reader :options, :evidence, :profile, :truncated, :invalid, :components, :standalone_components,
      :participation, :variants, :pairs

    def composable_block(option)
      return display_block(option) if option.key?(:display_components)

      block = Array(option[:candidate_ids]).filter_map { |id| evidence[id] }
        .select { |entry| entry[:source] == "line" }
        .sort_by { |entry| [ entry[:page_index].to_i, entry[:provider_line_index].to_i, entry[:line_index].to_i ] }
      return unless block.size.between?(2, 3)
      return unless block.all? { |entry| entry[:text].length >= 2 }
      if block.all? { |entry| legacy_line?(entry) }
        return unless block.each_cons(2).all? { |left, right| left[:line_index] + 1 == right[:line_index] }
      else
        return unless block.all? { |entry| entry[:span_state] == "exact" && entry.key?(:page_index) }
        return unless block.each_cons(2).all? { |left, right| consecutive?(left, right) }
      end
      return unless compact(option[:value]) == compact(block.map { |entry| entry[:text] }.join(" "))

      block
    end

    def legacy_line?(entry)
      index = entry[:line_index]
      entry[:span_state] == "missing" && index.is_a?(Integer) && index.between?(0, StoreNameEvidence::MAX_LINE_INDEX) &&
        !entry.key?(:page_index) && !entry.key?(:provider_line_index) && !entry.key?(:span) && !entry.key?(:string_index_type) &&
        entry[:candidate_id] == "line_#{index}" && entry[:source_path] == "lines[#{index}]"
    end

    def display_block(option)
      displayed = option[:display_components]
      return unless displayed.is_a?(Array) && displayed.size.between?(2, 3)

      block = displayed.filter_map do |component|
        entry = evidence[component[:candidate_id]]
        next unless entry && entry[:source] == "line" && entry[:span_state] == "exact" && entry.key?(:page_index)
        next unless Array(option[:candidate_ids]).include?(entry[:candidate_id])

        entry.merge(text: component[:text])
      end
      return unless block.size == displayed.size && block.map { |entry| entry[:candidate_id] }.uniq.size == block.size
      return unless block.each_cons(2).all? { |left, right| ordered?(left, right) }
      return unless compact(option[:value]) == compact(block.map { |entry| entry[:text] }.join(" "))

      block
    end

    def consecutive?(left, right)
      ordered?(left, right) &&
        left[:provider_line_index] + 1 == right[:provider_line_index] &&
        left[:line_index] + 1 == right[:line_index]
    end

    def ordered?(left, right)
      left[:page_index] == right[:page_index] &&
        left[:provider_line_index] < right[:provider_line_index] &&
        left[:line_index] < right[:line_index] &&
        left[:string_index_type] == right[:string_index_type] &&
        left[:span][:offset] + left[:span][:length] <= right[:span][:offset]
    end

    def compact(value)
      StoreNameCandidateClassifier.new(profile: profile).normalize_compact_name(value).to_s.downcase
    end

    def compose(option, block)
      edges = block.each_cons(2).map do |left, right|
        ids = [ left[:candidate_id], right[:candidate_id] ]
        id = "store_relation_#{Digest::SHA256.hexdigest(ids.join(':'))[0, 32]}"
        pairs[id] = ids
        { id: id, joined_separator: joined_separator(left[:text], right[:text]) }
      end
      choices = edges.reduce([ [] ]) do |separators, edge|
        separators.flat_map { |prefix| [ edge[:joined_separator], " " ].uniq.map { |separator| prefix + [ separator ] } }
      end
      choices.filter_map do |separators|
        value = block.first[:text].dup
        separators.each_with_index { |separator, index| value << separator << block[index + 1][:text] }
        next if value.length > MAX_NAME_LENGTH

        ids = block.map { |entry| entry[:candidate_id] }
        id = "store_option_#{Digest::SHA256.hexdigest(JSON.generate([ SCHEMA_VERSION, ids, separators, value ]))[0, 32]}"
        components[id] = ids
        participation[id] = ids
        variants[id] = edges.each_with_index.to_h do |edge, index|
          # 同じ名称の構成要素でも空白を含むため、意味上の関係で区切りを固定しない。
          decisions = [ "same_name" ]
          decisions << "store_location" if separators[index] == " "
          [ edge[:id], decisions ]
        end
        option.except(:display_components).merge(option_id: id, value: value)
      end
    end

    def joined_separator(left, right)
      local = [ left, right ].all? { |text| text.match?(profile.store_local_script_pattern) }
      mixed = [ left, right ].any? { |text| text.match?(/[A-Za-z]/) }
      local && !mixed ? "" : " "
    end

    def component_ids(option, require_coverage: true)
      Array(option[:candidate_ids]).flat_map do |id|
        entry = evidence[id]
        next [ id ] unless entry && entry[:source] == "merchant_name" && entry[:span_state] == "exact"

        lines = evidence.values.select do |line|
          line[:source] == "line" && line[:span_state] == "exact" &&
            (!entry.key?(:page_index) || entry[:page_index] == line[:page_index]) &&
            entry[:string_index_type] == line[:string_index_type] &&
            line[:span][:offset] >= entry[:span][:offset] &&
            line[:span][:offset] + line[:span][:length] <= entry[:span][:offset] + entry[:span][:length]
        end
        lines.sort_by! { |line| [ line[:page_index].to_i, line[:provider_line_index].to_i ] }
        if lines.empty? || require_coverage && !complete_merchant_lines?(entry, lines)
          [ id ]
        else
          lines.map { |line| line[:candidate_id] }
        end
      end.uniq.sort
    end

    def complete_merchant_lines?(entry, lines)
      return false unless lines.first[:span][:offset] == entry[:span][:offset]
      return false unless lines.last[:span][:offset] + lines.last[:span][:length] == entry[:span][:offset] + entry[:span][:length]
      return false unless lines.each_cons(2).all? { |left, right| consecutive?(left, right) }

      compact(entry[:text]) == compact(lines.map { |line| line[:text] }.join(" "))
    end

    def standalone_component(option)
      return if option.key?(:display_components) || Array(option[:candidate_ids]).size != 1

      entry = evidence[option[:candidate_ids].first]
      return unless entry && entry[:span_state] == "exact" && entry[:source] == option[:source]

      ids = components.fetch(option[:option_id])
      return unless ids.one?

      component = evidence[ids.first]
      return unless component && component[:source] == "line" && component[:span_state] == "exact"
      return unless entry[:span] == component[:span] && entry[:string_index_type] == component[:string_index_type]

      names = [ option[:value], entry[:text], component[:text] ].map do |text|
        StoreNameCandidateClassifier.new(profile: profile).normalize_name(text).to_s
      end
      ids.first if names.uniq.one?
    end

    def unclassified_composition?(option, relations)
      used = participation.fetch(option[:option_id])
      relations.any? do |relation|
        (used & relation[:candidate_ids]).size == 2 &&
          !(relation[:same_name_option_ids] | relation[:store_location_option_ids]).include?(option[:option_id])
      end
    end

    def deduplicate(entries)
      aliases = {}
      groups = entries.group_by { |option| [ components.fetch(option[:option_id]).sort, option[:value] ] }
      unique = groups.values.map do |group|
        chosen = group.min_by { |option| [ option[:source] == "merchant_name" ? 0 : 1, option[:option_id] ] }
        group.each { |option| aliases[option[:option_id]] = chosen[:option_id] }
        # 同じ印字成分と表示の候補をまとめても、確認に使う出典は捨てない。
        chosen.merge(
          candidate_ids: group.flat_map { |option| option[:candidate_ids] }.uniq.sort,
          line_indexes: group.flat_map { |option| option[:line_indexes] }.uniq.sort
        )
      end
      [ unique.sort_by { |option| option[:option_id] }, aliases ]
    end

    def build_relations(entries, aliases)
      retained_ids = entries.map { |entry| entry[:option_id] }
      pairs.sort.map do |id, ids|
        same_name = []
        location = []
        separate = []
        variants.each do |option_id, interpretations|
          decisions = interpretations[id]
          next unless decisions

          target_id = aliases.fetch(option_id)
          next unless retained_ids.include?(target_id)

          same_name << target_id if decisions.include?("same_name")
          location << target_id if decisions.include?("store_location")
        end
        entries.each do |option|
          overlap = components.fetch(option[:option_id]) & ids
          separate << option[:option_id] if overlap.one?
        end
        {
          relation_id: id, candidate_ids: ids,
          same_name_option_ids: same_name.uniq.sort,
          store_location_option_ids: location.uniq.sort,
          separate_option_ids: separate.uniq.sort,
          left_complete_option_ids: standalone_option_ids(ids.first, aliases, retained_ids),
          right_complete_option_ids: standalone_option_ids(ids.last, aliases, retained_ids)
        }
      end
    end

    def standalone_option_ids(component_id, aliases, retained_ids)
      standalone_components.filter_map do |option_id, id|
        next unless id == component_id

        selected_id = aliases.fetch(option_id)
        selected_id if retained_ids.include?(selected_id)
      end.uniq.sort
    end

    def envelope(entries, relations, invalid:)
      result = {
        schema_version: SCHEMA_VERSION, options: entries, relations: relations,
        truncated: truncated || options.size > MAX_OPTIONS, invalid: invalid
      }
      result[:checksum] = Digest::SHA256.hexdigest(JSON.generate(result))
      result
    end
  end
end
