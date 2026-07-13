require "pathname"
require "prism"
require "set"

module ServiceLayerBoundary
  TARGET_GLOBS = %w[
    app/controllers/**/*.rb
    app/jobs/**/*.rb
    app/models/**/*.rb
    app/helpers/**/*.rb
    app/presenters/**/*.rb
    app/mailers/**/*.rb
    app/views/**/*.erb
    app/services/**/*.rb
    app/queries/**/*.rb
    app/forms/**/*.rb
    app/policies/**/*.rb
    app/components/**/*.rb
    app/components/**/*.erb
    config/**/*.rb
    lib/**/*.rb
    lib/**/*.rake
  ].freeze

  Reference = Data.define(:constant_name, :line, :lexical_namespace, :absolute)
  ReferenceCandidate = Data.define(:constant_name, :resolution_root)
  Definition = Data.define(:constant_name, :line)
  Issue = Data.define(:source_path, :line, :message)
  Violation = Data.define(:source_path, :line, :referenced_constant, :private_owner)

  class SourceAnalyzer
    attr_reader :references, :definitions, :issues

    def initialize(source_path:, line_offset: 0)
      @source_path = source_path
      @line_offset = line_offset
      @references = []
      @definitions = []
      @issues = []
    end

    def analyze(source)
      result = Prism.parse(source)
      unless result.success?
        result.errors.each do |error|
          issues << Issue.new(
            source_path: source_path,
            line: adjusted_line(error.location.start_line),
            message: error.message
          )
        end
        return self
      end

      walk(result.value, lexical_namespace: nil)
      self
    end

    private

    attr_reader :source_path, :line_offset

    def walk(node, lexical_namespace:)
      return if node.nil?

      case node
      when Prism::ModuleNode
        walk_namespace_node(node, lexical_namespace: lexical_namespace)
      when Prism::ClassNode
        walk(node.superclass, lexical_namespace: lexical_namespace)
        walk_namespace_node(node, lexical_namespace: lexical_namespace)
      when Prism::ConstantWriteNode
        record_definition(qualify_definition(node.name.to_s, lexical_namespace), node.location.start_line)
        node.compact_child_nodes.each { |child| walk(child, lexical_namespace: lexical_namespace) }
      when Prism::ConstantPathWriteNode
        record_constant_path_definition(node.target, lexical_namespace)
        node.compact_child_nodes.reject { |child| child.equal?(node.target) }.each do |child|
          walk(child, lexical_namespace: lexical_namespace)
        end
      when Prism::ConstantPathNode
        record_constant_path_reference(node, lexical_namespace)
      when Prism::ConstantReadNode
        references << Reference.new(
          constant_name: node.name.to_s,
          line: adjusted_line(node.location.start_line),
          lexical_namespace: lexical_namespace,
          absolute: false
        )
      when Prism::CallNode
        record_dynamic_constant_reference(node, lexical_namespace)
        node.compact_child_nodes.each { |child| walk(child, lexical_namespace: lexical_namespace) }
      else
        node.compact_child_nodes.each { |child| walk(child, lexical_namespace: lexical_namespace) }
      end
    end

    def record_dynamic_constant_reference(node, lexical_namespace)
      name = dynamic_constant_name(node)
      return unless name

      references << Reference.new(
        constant_name: name.delete_prefix("::"),
        line: adjusted_line(node.location.start_line),
        lexical_namespace: lexical_namespace,
        absolute: name.start_with?("::")
      )
    end

    def dynamic_constant_name(node)
      case node.name
      when :constantize, :safe_constantize
        static_constant_literal(node.receiver)
      when :const_get
        const_get_constant_name(node)
      end
    end

    def const_get_constant_name(node)
      name = static_constant_literal(node.arguments&.arguments&.first)
      return unless name
      return name if name.start_with?("::")

      receiver_name = full_name(node.receiver) if node.receiver&.respond_to?(:full_name)
      return name if receiver_name.blank? || receiver_name.delete_prefix("::") == "Object"

      "#{receiver_name}::#{name}"
    end

    def static_constant_literal(node)
      return unless node.is_a?(Prism::StringNode) || node.is_a?(Prism::SymbolNode)

      value = node.unescaped.to_s
      value if value.match?(/\A(?:::)?[A-Z][A-Za-z0-9]*(?:::[A-Z][A-Za-z0-9]*)*\z/)
    end

    def walk_namespace_node(node, lexical_namespace:)
      namespace = full_name(node.constant_path)
      return unless namespace

      qualified = qualify_definition(namespace, lexical_namespace)
      record_definition(qualified, node.constant_path.location.start_line)
      references << Reference.new(
        constant_name: namespace.delete_prefix("::"),
        line: adjusted_line(node.constant_path.location.start_line),
        lexical_namespace: lexical_namespace,
        absolute: namespace.start_with?("::")
      )
      walk(node.body, lexical_namespace: qualified)
    end

    def record_constant_path_definition(node, lexical_namespace)
      name = full_name(node)
      record_definition(qualify_definition(name, lexical_namespace), node.location.start_line) if name
    end

    def record_constant_path_reference(node, lexical_namespace)
      name = full_name(node)
      return unless name

      references << Reference.new(
        constant_name: name.delete_prefix("::"),
        line: adjusted_line(node.location.start_line),
        lexical_namespace: lexical_namespace,
        absolute: name.start_with?("::")
      )
    end

    def full_name(node)
      node.full_name
    rescue Prism::DynamicPartsInConstantPathError
      issues << Issue.new(
        source_path: source_path,
        line: adjusted_line(node.location.start_line),
        message: "dynamic constant path cannot be checked"
      )
      nil
    end

    def qualify_definition(name, lexical_namespace)
      normalized = name.delete_prefix("::")
      return normalized if name.start_with?("::") || lexical_namespace.blank?
      return normalized if normalized.split("::").first == lexical_namespace.split("::").first

      "#{lexical_namespace}::#{normalized}"
    end

    def record_definition(name, line)
      definitions << Definition.new(constant_name: name, line: adjusted_line(line))
    end

    def adjusted_line(line)
      [ line + line_offset, 1 ].max
    end
  end

  class Scanner
    REQUIRED_REGISTRY_KEYS = %i[
      namespace
      private_root
      internal_reference_roots
      public_facades
      public_constants
      legacy_exceptions
    ].freeze

    attr_reader :root, :registry

    def initialize(root:, registry:, constant_path_resolver: nil)
      @root = Pathname(root)
      @registry = registry.transform_keys(&:to_s)
      @constant_path_resolver = constant_path_resolver || method(:default_constant_path)
      @source_analysis = {}
    end

    def target_files
      TARGET_GLOBS.flat_map { |glob| root.glob(glob) }.select(&:file?).uniq.sort
    end

    def actual_service_directories
      services_root.children.select(&:directory?).map { |path| path.basename.to_s }.sort
    end

    def unregistered_service_directories
      actual_service_directories - registry.keys.sort
    end

    def stale_registry_directories
      registry.keys.sort - actual_service_directories
    end

    def registry_issues
      issues = []
      issues.concat(unregistered_service_directories.map { |name| "unregistered service directory: #{name}" })
      issues.concat(stale_registry_directories.map { |name| "stale service registry entry: #{name}" })

      registry.each do |directory, entry|
        issues.concat(entry_issues(directory, entry))
      end

      duplicate_legacy_keys.each do |source_path, referenced_constant|
        issues << "duplicate legacy exception: #{source_path} -> #{referenced_constant}"
      end
      issues
    end

    def catalog_issues
      issues = service_child_files.flat_map do |directory, path|
        child_catalog_issues(directory, path)
      end
      issues.concat(public_constant_issues)
      issues.concat(legacy_exception_issues)
      issues
    end

    def analysis_issues
      target_files.flat_map { |path| analysis_for(path).issues }.uniq
    end

    def private_constants
      private_constant_owners.keys.sort
    end

    def private_constant_paths
      service_child_files.to_h do |_directory, path|
        [ relative_path(path), expected_constant_path(path) ]
      end
    end

    def violations
      target_files.flat_map do |path|
        source_path = relative_path(path)
        analysis_for(path).references.filter_map do |reference|
          resolved = resolve_private_reference(reference)
          next unless resolved

          referenced_constant, private_owner = resolved
          next if allowed_reference?(source_path, referenced_constant, private_owner)

          Violation.new(
            source_path: source_path,
            line: reference.line,
            referenced_constant: referenced_constant,
            private_owner: private_owner
          )
        end
      end.uniq.sort_by { |violation| [ violation.source_path, violation.line, violation.referenced_constant ] }
    end

    def unused_legacy_exceptions
      used = target_files.flat_map do |path|
        source_path = relative_path(path)
        analysis_for(path).references.filter_map do |reference|
          resolved = resolve_private_reference(reference)
          next unless resolved

          referenced_constant, private_owner = resolved
          key = [ source_path, referenced_constant ]
          key if legacy_exception_keys.include?(key) && !normally_allowed?(source_path, referenced_constant, private_owner)
        end
      end.uniq

      legacy_exceptions.reject do |exception|
        used.include?([ exception.fetch(:source_path), exception.fetch(:referenced_constant) ])
      end
    end

    def format_violations(found = violations)
      lines = found.map do |violation|
        "#{violation.source_path}:#{violation.line} -> #{violation.referenced_constant} " \
          "(private owner: #{violation.private_owner})"
      end
      ([ "Service layer boundary violations:" ] + lines + [ "", format_legacy_exceptions ]).join("\n")
    end

    def format_legacy_exceptions(exceptions = legacy_exceptions)
      lines = exceptions.sort_by { |entry| [ entry.fetch(:source_path), entry.fetch(:referenced_constant) ] }.map do |entry|
        "#{entry.fetch(:source_path)} -> #{entry.fetch(:referenced_constant)} " \
          "(remove in Loop #{entry.fetch(:remove_in_loop)}: #{entry.fetch(:reason)})"
      end
      ([ "Exact legacy exceptions:" ] + lines).join("\n")
    end

    private

    attr_reader :constant_path_resolver, :source_analysis

    def services_root
      root.join("app/services")
    end

    def relative_path(path)
      Pathname(path).relative_path_from(root).to_s
    end

    def service_child_files
      registry.keys.sort.flat_map do |directory|
        root.glob("#{registry.fetch(directory).fetch(:private_root)}/**/*.rb").sort.map do |path|
          [ directory, path ]
        end
      end
    end

    def facade_files(directory)
      registry.fetch(directory).fetch(:public_facades).map { |path| root.join(path) }.select(&:file?)
    end

    def owned_constants(directory)
      @owned_constants ||= {}
      @owned_constants[directory] ||= begin
        entry = registry.fetch(directory)
        namespace = entry.fetch(:namespace)
        paths = service_child_files.filter_map { |owner, path| path if owner == directory } + facade_files(directory)
        definitions = paths.flat_map { |path| analysis_for(path).definitions.map(&:constant_name) }
        expected = paths.filter_map do |path|
          expected_constant_path(path) if path.to_s.start_with?(root.join(entry.fetch(:private_root)).to_s + File::SEPARATOR)
        end

        (definitions + expected).compact.uniq.select do |constant|
          constant.start_with?("#{namespace}::")
        end.sort
      end
    end

    def private_constant_owners
      @private_constant_owners ||= registry.each_with_object({}) do |(directory, entry), owners|
        public_constants = entry.fetch(:public_constants)
        owned_constants(directory).each do |constant|
          next if public_constants.include?(constant)

          owners[constant] = directory
        end
      end
    end

    def expected_constant_path(path)
      constant_path_resolver.call(Pathname(path))
    end

    def default_constant_path(path)
      relative = Pathname(path).relative_path_from(services_root).sub_ext("").to_s
      ActiveSupport::Inflector.camelize(relative)
    end

    def analysis_for(path)
      source_analysis[path.to_s] ||= begin
        if path.to_s.end_with?(".erb")
          compiled = ActionView::Template::Handlers::ERB.erb_implementation.new(path.read, trim: true).src
          SourceAnalyzer.new(source_path: relative_path(path), line_offset: -1)
            .analyze("def __service_layer_boundary_template__\n#{compiled}\nend")
        else
          SourceAnalyzer.new(source_path: relative_path(path)).analyze(path.read)
        end
      end
    end

    def resolve_private_reference(reference)
      reference_candidates(reference).each do |candidate|
        owner_constant = private_constant_owners.keys
          .select do |constant|
            resolved_constant?(candidate, constant) &&
              (constant == candidate.resolution_root || constant.start_with?("#{candidate.resolution_root}::"))
          end
          .max_by(&:length)
        return [ candidate.constant_name, private_constant_owners.fetch(owner_constant) ] if owner_constant
      end
      nil
    end

    def reference_candidates(reference)
      root_name = reference.constant_name.split("::").first
      top_level = ReferenceCandidate.new(
        constant_name: reference.constant_name,
        resolution_root: root_name
      )
      return [ top_level ] if reference.absolute

      scopes = reference.lexical_namespace.to_s.split("::")
      lexical_candidates = scopes.length.downto(1).map do |length|
        scope = scopes.first(length).join("::")
        ReferenceCandidate.new(
          constant_name: "#{scope}::#{reference.constant_name}",
          resolution_root: "#{scope}::#{root_name}"
        )
      end
      (lexical_candidates + [ top_level ]).uniq
    end

    def resolved_constant?(candidate, private_constant)
      candidate.constant_name == private_constant ||
        candidate.constant_name.start_with?("#{private_constant}::")
    end

    def allowed_reference?(source_path, referenced_constant, private_owner)
      normally_allowed?(source_path, referenced_constant, private_owner) ||
        legacy_exception_keys.include?([ source_path, referenced_constant ])
    end

    def normally_allowed?(source_path, referenced_constant, private_owner)
      entry = registry.fetch(private_owner)
      entry.fetch(:public_constants).include?(referenced_constant) ||
        entry.fetch(:public_facades).include?(source_path) ||
        entry.fetch(:internal_reference_roots).any? do |internal_root|
          source_path.start_with?("#{internal_root}/")
        end
    end

    def legacy_exceptions
      registry.values.flat_map { |entry| entry.fetch(:legacy_exceptions) }
    end

    def legacy_exception_keys
      @legacy_exception_keys ||= legacy_exceptions.map do |exception|
        [ exception.fetch(:source_path), exception.fetch(:referenced_constant) ]
      end.to_set
    end

    def duplicate_legacy_keys
      legacy_exception_keys_array = legacy_exceptions.map do |exception|
        [ exception.fetch(:source_path), exception.fetch(:referenced_constant) ]
      end
      legacy_exception_keys_array.tally.select { |_key, count| count > 1 }.keys
    end

    def entry_issues(directory, entry)
      issues = []
      missing_keys = REQUIRED_REGISTRY_KEYS - entry.keys
      issues << "#{directory}: missing registry keys: #{missing_keys.join(", ")}" if missing_keys.any?
      return issues if missing_keys.any?

      expected_root = "app/services/#{directory}"
      issues << "#{directory}: private_root must be #{expected_root}" unless entry.fetch(:private_root) == expected_root
      unless entry.fetch(:internal_reference_roots) == [ expected_root ]
        issues << "#{directory}: internal_reference_roots must be the exact private_root only"
      end
      issues << "#{directory}: namespace must be a top-level constant" unless entry.fetch(:namespace).match?(/\A[A-Z][A-Za-z0-9]*\z/)

      entry.fetch(:public_facades).each do |path|
        issues << "#{directory}: missing public facade: #{path}" unless root.join(path).file?
        unless path.match?(%r{\Aapp/services/[^/]+\.rb\z})
          issues << "#{directory}: public facade must be an exact app/services root file: #{path}"
        end
      end
      entry.fetch(:public_constants).each do |constant|
        unless constant.start_with?("#{entry.fetch(:namespace)}::")
          issues << "#{directory}: public constant is outside namespace: #{constant}"
        end
      end
      issues
    end

    def child_catalog_issues(directory, path)
      expected = expected_constant_path(path)
      relative = relative_path(path)
      return [ "#{relative}: Zeitwerk has no expected constant path" ] if expected.blank?

      namespace = registry.fetch(directory).fetch(:namespace)
      issues = []
      issues << "#{relative}: expected #{expected} outside #{namespace}" unless expected.start_with?("#{namespace}::")
      definitions = analysis_for(path).definitions.map(&:constant_name)
      unless definitions.include?(expected)
        issues << "#{relative}: expected #{expected}, defined #{definitions.sort.join(", ")}"
      end
      issues
    end

    def public_constant_issues
      registry.flat_map do |directory, entry|
        entry.fetch(:public_constants).filter_map do |constant|
          "#{directory}: public constant is not defined by its facade/private root: #{constant}" unless owned_constants(directory).include?(constant)
        end
      end
    end

    def legacy_exception_issues
      legacy_exceptions.flat_map do |exception|
        issues = []
        source_path = exception[:source_path]
        referenced_constant = exception[:referenced_constant]
        if source_path.blank? || source_path.match?(/[\*?\[\]]/)
          issues << "legacy exception must use an exact source_path: #{source_path.inspect}"
        elsif !root.join(source_path).file?
          issues << "legacy exception source does not exist: #{source_path}"
        end
        if referenced_constant.blank? || referenced_constant.match?(/[\*?\[\]]/)
          issues << "legacy exception must use an exact referenced_constant: #{referenced_constant.inspect}"
        end
        issues << "legacy exception reason is required: #{source_path} -> #{referenced_constant}" if exception[:reason].blank?
        unless exception[:remove_in_loop].is_a?(Integer) && exception[:remove_in_loop].between?(2, 22)
          issues << "legacy exception remove_in_loop must be 2..22: #{source_path} -> #{referenced_constant}"
        end
        if referenced_constant.present? && !referenced_constant.match?(/[\*?\[\]]/) && !private_reference_name?(referenced_constant)
          issues << "legacy exception is not a private constant reference: #{source_path} -> #{referenced_constant}"
        end
        issues
      end
    end

    def private_reference_name?(referenced_constant)
      private_constant_owners.keys.any? do |constant|
        referenced_constant == constant || referenced_constant.start_with?("#{constant}::")
      end
    end
  end
end
