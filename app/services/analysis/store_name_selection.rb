module Analysis
  class StoreNameSelection
    DECISIONS = %w[select ambiguous reject invalid].freeze
    KEYS = %w[decision option_id options_checksum options_schema_version relations].freeze
    OPTIONS_SCHEMA_VERSIONS = %w[store_name_options_v1 store_name_options_v2].freeze
    RELATION_KEYS = %w[relation_id decision].freeze
    RELATION_OPTION_KEYS = %w[
      relation_id candidate_ids same_name_option_ids store_location_option_ids separate_option_ids
      left_complete_option_ids right_complete_option_ids
    ].freeze
    RELATION_DECISIONS = %w[same_name store_location left_complete right_complete unrelated ambiguous].freeze
    RELATION_OPTION_FIELDS = {
      "same_name" => :same_name_option_ids,
      "store_location" => :store_location_option_ids,
      "left_complete" => :left_complete_option_ids,
      "right_complete" => :right_complete_option_ids,
      "unrelated" => :separate_option_ids
    }.freeze
    OPTION_ID_PATTERN = /\Astore_option_[0-9a-f]{32}\z/
    RELATION_ID_PATTERN = /\Astore_relation_[0-9a-f]{32}\z/
    CANDIDATE_ID_PATTERN = /\A(?:merchant_name|legacy_store|(?:page_\d{1,2}_)?line_\d{1,4})\z/
    CHECKSUM_PATTERN = /\A[0-9a-f]{64}\z/

    class << self
      def call(value, options: nil)
        return if value.nil? && options.nil?

        selection = normalize(value)
        return selection unless options.is_a?(Hash)

        bind(selection, options)
      end

      private

      def normalize(value)
        return invalid unless value.is_a?(Hash) && value.size <= KEYS.size
        return invalid unless value.keys.all? { |key| (key.is_a?(String) || key.is_a?(Symbol)) && KEYS.include?(key.to_s) }

        data = value.symbolize_keys
        return invalid unless data.size == value.size
        return invalid unless DECISIONS.include?(data[:decision])
        return invalid if data[:options_checksum] && !valid_checksum?(data[:options_checksum])
        return invalid if data.key?(:options_schema_version) && !valid_options_schema_version?(data[:options_schema_version])
        return invalid unless valid_option?(data)

        relations = normalized_relations(data[:relations]) if data.key?(:relations)
        return invalid if data.key?(:relations) && relations.nil?
        return invalid if data[:options_schema_version] == "store_name_options_v1" && relations&.any?

        {
          decision: data[:decision],
          option_id: data[:option_id],
          options_checksum: data[:options_checksum],
          options_schema_version: data[:options_schema_version],
          relations: relations
        }.compact
      end

      def valid_option?(data)
        return data[:option_id].nil? unless data[:decision] == "select"

        valid_identifier?(data[:option_id], OPTION_ID_PATTERN)
      end

      def valid_identifier?(value, pattern)
        value.is_a?(String) && value.valid_encoding? && value.bytesize <= 100 && pattern.match?(value)
      end

      def valid_checksum?(value)
        value.is_a?(String) && value.valid_encoding? && value.bytesize == 64 && CHECKSUM_PATTERN.match?(value)
      end

      def valid_options_schema_version?(value)
        value.is_a?(String) && value.valid_encoding? && value.bytesize <= 64 && OPTIONS_SCHEMA_VERSIONS.include?(value)
      end

      def bind(selection, options)
        checksum = options[:checksum] || options["checksum"]
        return invalid unless valid_checksum?(checksum)

        attributes = { options_checksum: checksum }
        version = options[:schema_version] || options["schema_version"]
        if options.key?(:schema_version) || options.key?("schema_version")
          return invalid.merge(attributes) unless valid_options_schema_version?(version)

          attributes[:options_schema_version] = version
        end
        if selection[:options_schema_version] && selection[:options_schema_version] != version
          return invalid.merge(attributes)
        end
        if selection[:options_checksum] && selection[:options_checksum] != checksum
          return invalid.merge(attributes)
        end
        return invalid.merge(attributes) if selection[:decision] == "invalid"

        entries = options[:options] || options["options"]
        if selection[:decision] == "select" && !unique_option?(entries, selection[:option_id])
          return invalid.merge(attributes)
        end

        if version == "store_name_options_v2"
          return invalid.merge(attributes) unless valid_relation_selection?(selection, options, entries)

          selection.merge(attributes).merge(relations: selection.fetch(:relations, []))
        else
          return invalid.merge(attributes) if selection[:relations]&.any?

          selection.except(:relations).merge(attributes)
        end
      end

      def normalized_relations(value)
        return unless bounded_array?(value)

        relations = value.map do |entry|
          relation = exact_hash(entry, RELATION_KEYS)
          return unless relation && valid_identifier?(relation[:relation_id], RELATION_ID_PATTERN)
          return unless RELATION_DECISIONS.include?(relation[:decision])

          relation
        end
        relations if relations.map { |relation| relation[:relation_id] }.uniq.size == relations.size
      end

      def valid_relation_selection?(selection, options, entries)
        relations = normalized_option_relations(options[:relations] || options["relations"], entries)
        return false unless relations

        answers = selection.fetch(:relations, []).index_by { |answer| answer[:relation_id] }
        relation_ids = relations.map { |relation| relation[:relation_id] }
        return false unless (answers.keys - relation_ids).empty?
        return true unless selection[:decision] == "select"
        return false unless answers.size == relations.size

        direct_relations_valid = relations.all? do |relation|
          related = RELATION_OPTION_FIELDS.values.any? { |field| relation[field].include?(selection[:option_id]) }
          next true unless related

          field = RELATION_OPTION_FIELDS[answers.fetch(relation[:relation_id])[:decision]]
          field && relation[field].include?(selection[:option_id])
        end
        return false unless direct_relations_valid

        aliases = selected_alias_components(relations, answers, selection[:option_id])
        relations.all? { |relation| valid_alias_relation?(relation, answers.fetch(relation[:relation_id])[:decision], aliases, selection[:option_id]) }
      end

      def selected_alias_components(relations, answers, option_id)
        links = Hash.new { |hash, key| hash[key] = [] }
        pending = []
        relations.each do |relation|
          decision = answers.fetch(relation[:relation_id])[:decision]
          components = complete_relation_components(relation, decision)
          next unless components

          complete, alternative = components
          links[complete] << alternative
          pending << complete if relation.fetch(RELATION_OPTION_FIELDS.fetch(decision)).include?(option_id)
        end

        aliases = {}
        index = 0
        while index < pending.size
          component = pending[index]
          index += 1
          next if aliases.key?(component)

          aliases[component] = true
          pending.concat(links[component])
        end
        aliases
      end

      def valid_alias_relation?(relation, decision, aliases, option_id)
        related_count = relation[:candidate_ids].count { |id| aliases.key?(id) }
        return true if related_count.zero?
        return related_count == 1 if decision == "unrelated"

        components = complete_relation_components(relation, decision)
        return aliases.key?(components.first) if components

        field = RELATION_OPTION_FIELDS[decision]
        field && relation[field].include?(option_id)
      end

      def complete_relation_components(relation, decision)
        case decision
        when "left_complete"
          relation[:candidate_ids] if relation[:left_complete_option_ids].any?
        when "right_complete"
          relation[:candidate_ids].reverse if relation[:right_complete_option_ids].any?
        end
      end

      def normalized_option_relations(value, entries)
        return unless bounded_array?(value) && bounded_array?(entries)

        option_ids = entries.map do |entry|
          return unless entry.is_a?(Hash)

          id = entry[:option_id] || entry["option_id"]
          return unless valid_identifier?(id, OPTION_ID_PATTERN)

          id
        end
        return unless option_ids.uniq.size == option_ids.size

        relations = value.map do |entry|
          relation = exact_hash(entry, RELATION_OPTION_KEYS)
          return unless relation && valid_identifier?(relation[:relation_id], RELATION_ID_PATTERN)
          return unless valid_relation_components?(relation[:candidate_ids])
          return unless valid_relation_option_ids?(relation, option_ids)

          relation
        end
        relations if relations.map { |relation| relation[:relation_id] }.uniq.size == relations.size
      end

      def valid_relation_components?(value)
        value.is_a?(Array) && value.size == 2 && value.uniq.size == 2 &&
          value.all? { |id| valid_identifier?(id, CANDIDATE_ID_PATTERN) }
      end

      def valid_relation_option_ids?(relation, option_ids)
        return false unless RELATION_OPTION_FIELDS.values.all? do |field|
          ids = relation[field]
          bounded_array?(ids) && ids.all? { |id| valid_identifier?(id, OPTION_ID_PATTERN) } &&
            ids.uniq.size == ids.size && (ids - option_ids).empty?
        end

        combined = relation[:same_name_option_ids] | relation[:store_location_option_ids]
        separate = relation[:separate_option_ids]
        left_complete = relation[:left_complete_option_ids]
        right_complete = relation[:right_complete_option_ids]
        (combined & separate).empty? && (left_complete - separate).empty? && (right_complete - separate).empty? &&
          (left_complete & right_complete).empty?
      end

      def bounded_array?(value)
        value.is_a?(Array) && value.size <= StoreNameEvidence::MAX_CANDIDATES
      end

      def exact_hash(value, keys)
        return unless value.is_a?(Hash) && value.size == keys.size
        return unless value.keys.all? { |key| (key.is_a?(String) || key.is_a?(Symbol)) && keys.include?(key.to_s) }

        normalized = value.symbolize_keys
        normalized if normalized.size == value.size
      end

      def unique_option?(entries, option_id)
        return false unless entries.is_a?(Array) && entries.size <= StoreNameEvidence::MAX_CANDIDATES

        entries.count { |entry| entry.is_a?(Hash) && (entry[:option_id] || entry["option_id"]) == option_id } == 1
      end

      def invalid
        { decision: "invalid" }
      end
    end
  end
end
