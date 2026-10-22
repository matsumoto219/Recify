module ExternalServices
  class ErrorDiagnostic
    SCHEMA_VERSION = "external_service_error_diagnostic_v1".freeze
    MAX_BODY_BYTES = 65_536
    MAX_BYTES = 98_304
    MAX_NODES = 16
    MAX_DEPTH = 4
    MAX_OMISSIONS = 128
    IDENTIFIER_FIELDS = %i[code type param target reason].freeze
    NODE_KEYS = (IDENTIFIER_FIELDS + %i[path message_safe]).freeze
    LOCAL_ISSUES = %w[
      invalid_json
      refusal
      incomplete
      timeout
      invalid_response
      connection_failed
      invalid_operation_location
    ].freeze
    OMISSION_REASONS = %w[
      redacted
      invalid_type
      invalid_encoding
      byte_limit
      depth_limit
      node_limit
      unknown_version
      invalid_structure
      invalid_json
      omission_limit
      unsupported_fields
    ].freeze
    INNER_KEYS = %i[innererror innerError].freeze

    class << self
      def build(**attributes)
        new(**attributes).to_h
      end
    end

    def initialize(body: nil, diagnostic: nil, local_issue: nil)
      @body = body
      @diagnostic = diagnostic
      @local_issue = local_issue
      @nodes = []
      @omissions = []
    end

    def to_h
      return if @body.nil? && @diagnostic.nil? && @local_issue.nil?

      if @diagnostic.nil?
        extract_body unless @body.nil?
      else
        restore_diagnostic
      end
      add_local_issue(@local_issue) unless @local_issue.nil?

      result = {
        schema_version: SCHEMA_VERSION,
        nodes: @nodes,
        omissions: @omissions
      }
      result[:local_issue] = @normalized_local_issue if @normalized_local_issue
      return result if JSON.generate(result).bytesize <= MAX_BYTES

      {
        schema_version: SCHEMA_VERSION,
        nodes: [],
        omissions: [ { path: "diagnostic", reason: "byte_limit" } ]
      }
    end

    private

    def extract_body
      parsed = parse_body
      return unless parsed

      source = field(parsed, :error)
      incomplete_details = field(parsed, :incomplete_details)
      unless source.nil?
        source = { message: source } if source.is_a?(String)
        extract_node(source, path: "error", depth: 0)
      end
      if source.nil? && incomplete_details.nil?
        extract_node(parsed, path: "error", depth: 0, report_unknown: false)
      end
      extract_node(incomplete_details, path: "incomplete_details", depth: 0) unless incomplete_details.nil?
    end

    def parse_body
      return @body if @body.is_a?(Hash)
      return omit("body", "invalid_type") unless @body.is_a?(String)
      return omit("body", "byte_limit") if @body.bytesize > MAX_BODY_BYTES
      return omit("body", "invalid_encoding") unless @body.valid_encoding?

      parsed = JSON.parse(@body)
      return omit("body", "invalid_type") unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError, EncodingError, ArgumentError
      omit("body", "invalid_json")
    end

    def extract_node(value, path:, depth:, report_unknown: true)
      return omit(path, "depth_limit") if depth > MAX_DEPTH
      return omit(path, "node_limit") if @nodes.size >= MAX_NODES
      return omit(path, "invalid_type") unless value.is_a?(Hash)

      source_keys = IDENTIFIER_FIELDS + INNER_KEYS + %i[message details]
      omit(path, "unsupported_fields") if report_unknown && !known_keys?(value, source_keys)
      @nodes << normalized_node(value, path: path, message_key: :message)
      INNER_KEYS.each do |key|
        child = field(value, key)
        extract_node(child, path: "#{path}.#{key}", depth: depth + 1) unless child.nil?
      end
      extract_details(field(value, :details), path: path, depth: depth)
    end

    def extract_details(details, path:, depth:)
      return if details.nil?
      return omit("#{path}.details", "invalid_type") unless details.is_a?(Array)

      details.first(MAX_NODES).each_with_index do |child, index|
        if @nodes.size >= MAX_NODES
          omit("#{path}.details", "node_limit")
          break
        end
        extract_node(child, path: "#{path}.details[#{index}]", depth: depth + 1)
      end
      omit("#{path}.details", "node_limit") if details.size > MAX_NODES
    end

    def normalized_node(value, path:, message_key:)
      node = { path: path }
      IDENTIFIER_FIELDS.each do |key|
        source = field(value, key)
        next if source.nil?

        sanitized = safe_identifier(source, path: "#{path}.#{key}", structural: %i[param target].include?(key))
        node[key] = sanitized if sanitized
      end
      message = field(value, message_key)
      unless message.nil?
        sanitized = ErrorTextSanitizer.diagnostic_message(message)
        node[:message_safe] = sanitized[:value] if sanitized[:value]
        omit("#{path}.message", sanitized[:reason]) if sanitized[:reason]
      end
      node
    end

    def safe_identifier(value, path:, structural: false)
      return omit(path, "invalid_type") unless value.is_a?(String)
      return omit(path, "byte_limit") if value.bytesize > ErrorTextSanitizer::MAX_BYTES
      return omit(path, "invalid_encoding") unless value.valid_encoding?
      return omit(path, "redacted") if ErrorTextSanitizer::SENSITIVE_PATTERNS.any? { |pattern| value.match?(pattern) }

      sanitized = ErrorTextSanitizer.call(value, identifier: true)
      return sanitized if sanitized
      if structural && value.ascii_only? && value.match?(/\A[A-Za-z_][A-Za-z0-9_.]*(?:\[\d+\](?:\.[A-Za-z_][A-Za-z0-9_]*)?)+\z/)
        return value
      end

      omit(path, "invalid_structure")
    rescue EncodingError, ArgumentError
      omit(path, "invalid_encoding")
    end

    def restore_diagnostic
      return omit("diagnostic", "invalid_type") unless @diagnostic.is_a?(Hash)
      return omit("diagnostic", "unknown_version") unless field(@diagnostic, :schema_version) == SCHEMA_VERSION

      allowed_keys = %i[schema_version nodes omissions local_issue]
      omit("diagnostic", "invalid_structure") unless known_keys?(@diagnostic, allowed_keys)
      restore_omissions(field(@diagnostic, :omissions))
      restore_nodes(field(@diagnostic, :nodes))
      local_issue = field(@diagnostic, :local_issue)
      add_local_issue(local_issue) unless local_issue.nil?
    end

    def restore_nodes(nodes)
      return omit("diagnostic", "invalid_type") unless nodes.is_a?(Array)

      nodes.first(MAX_NODES).each do |node|
        unless node.is_a?(Hash) && valid_path?(field(node, :path), node: true)
          omit("diagnostic", "invalid_structure")
          next
        end
        path = field(node, :path)
        if @nodes.any? { |existing| existing[:path] == path }
          omit("diagnostic", "invalid_structure")
          next
        end
        omit(path, "invalid_structure") unless known_keys?(node, NODE_KEYS)
        @nodes << normalized_node(node, path: path, message_key: :message_safe)
      end
      omit("diagnostic", "node_limit") if nodes.size > MAX_NODES
    end

    def restore_omissions(omissions)
      return omit("diagnostic", "invalid_type") unless omissions.is_a?(Array)

      omissions.first(MAX_OMISSIONS).each do |entry|
        unless entry.is_a?(Hash) && known_keys?(entry, %i[path reason]) &&
            valid_path?(field(entry, :path)) && OMISSION_REASONS.include?(field(entry, :reason))
          omit("diagnostic", "invalid_structure")
          next
        end
        omit(field(entry, :path), field(entry, :reason))
      end
      omit("diagnostic", "omission_limit") if omissions.size > MAX_OMISSIONS
    end

    def add_local_issue(value)
      return omit("local_issue", "invalid_structure") unless LOCAL_ISSUES.include?(value)

      @normalized_local_issue = value
    end

    def valid_path?(value, node: false)
      return false unless value.is_a?(String) && value.ascii_only? && value.bytesize <= 200
      return true if !node && %w[body diagnostic local_issue].include?(value)

      parts = value.split(".")
      return false unless %w[error incomplete_details].include?(parts.shift)

      fields = IDENTIFIER_FIELDS.map(&:to_s) + %w[message details]
      parts.pop if !node && fields.include?(parts.last)
      return false if parts.size > (node ? MAX_DEPTH : MAX_DEPTH + 1)

      parts.all? { |part| part.match?(/\A(?:innererror|innerError|details\[(?:[0-9]|1[0-5])\])\z/) }
    end

    def known_keys?(hash, keys)
      return false if hash.size > keys.size

      hash.keys.all? { |key| keys.include?(key) || (key.is_a?(String) && keys.any? { |known| known.to_s == key }) }
    end

    def field(hash, key)
      hash.key?(key) ? hash[key] : hash[key.to_s]
    end

    def omit(path, reason)
      entry = { path: path, reason: reason }
      return if @omissions.include?(entry)

      if @omissions.size < MAX_OMISSIONS - 1
        @omissions << entry
      elsif @omissions.last != { path: "diagnostic", reason: "omission_limit" }
        @omissions << { path: "diagnostic", reason: "omission_limit" }
      end
      nil
    end
  end
end
