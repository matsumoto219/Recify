require "pathname"
require_relative "service_layer_boundary_scanner"

module ReceiptWorkflowBoundary
  REQUIRED_REGISTRY_KEYS = %i[
    namespace
    facade_path
    private_root
    allowed_workflow_facades
    public_constants
  ].freeze
  SPECIALIST_SOURCE_ROOTS = %w[
    app/services/ai
    app/services/analysis
    app/services/amounts
    app/services/ocr
    app/services/receipt_analysis_profiles
  ].freeze
  SPECIALIST_FACADE_PATHS = %w[
    app/services/analysis.rb
    app/services/receipt_ai_enrichment_service.rb
    app/services/receipt_amount_service.rb
    app/services/receipt_analysis_profiles.rb
    app/services/receipt_ocr_service.rb
  ].freeze

  Violation = Data.define(
    :source_path,
    :line,
    :source_workflow,
    :target_workflow,
    :referenced_constant,
    :target_visibility,
    :rule
  )
  ResolvedReference = Data.define(
    :constant_name,
    :target_workflow,
    :visibility
  )

  class Scanner
    attr_reader :root, :registry

    def initialize(root:, registry:, constant_path_resolver: nil)
      @root = Pathname(root)
      @registry = registry.transform_keys(&:to_s)
      @constant_path_resolver = constant_path_resolver || method(:default_constant_path)
      @source_analysis = {}
    end

    def registry_issues
      issues = unknown_workflow_roots.map do |name|
        "unregistered receipt workflow root: #{name}"
      end

      registry.each do |workflow, entry|
        issues.concat(entry_issues(workflow, entry))
      end
      issues
    end

    def catalog_issues
      active_workflows.flat_map do |workflow|
        facade_catalog_issues(workflow) + private_catalog_issues(workflow)
      end + public_constant_issues
    end

    def analysis_issues
      target_files.flat_map { |path| analysis_for(path).issues }.uniq
    end

    def violations
      target_files.flat_map do |path|
        source_path = relative_path(path)
        source_workflow = workflow_for_source(source_path)

        analysis_for(path).references.filter_map do |reference|
          resolved = resolve_workflow_reference(reference)
          next unless resolved
          next if allowed_reference?(source_path, source_workflow, resolved)

          Violation.new(
            source_path: source_path,
            line: reference.line,
            source_workflow: source_workflow,
            target_workflow: resolved.target_workflow,
            referenced_constant: resolved.constant_name,
            target_visibility: resolved.visibility,
            rule: violation_rule(source_path, source_workflow, resolved)
          )
        end
      end.uniq.sort_by do |violation|
        [ violation.source_path, violation.line, violation.referenced_constant ]
      end
    end

    def private_constant_paths
      private_files.to_h do |workflow, path|
        [ relative_path(path), [ workflow, expected_constant_path(path) ] ]
      end
    end

    def format_violations(found = violations)
      lines = found.map do |violation|
        source = violation.source_workflow || "external"
        "#{violation.source_path}:#{violation.line} source=#{source} -> " \
          "#{violation.referenced_constant} " \
          "(#{violation.target_workflow} #{violation.target_visibility}, rule=#{violation.rule})"
      end

      ([ "Receipt workflow boundary violations:" ] + lines).join("\n")
    end

    private

    attr_reader :constant_path_resolver, :source_analysis

    def receipts_root
      root.join("app/services/receipts")
    end

    def services_root
      root.join("app/services")
    end

    def target_files
      ServiceLayerBoundary::TARGET_GLOBS.flat_map { |glob| root.glob(glob) }
        .select(&:file?)
        .uniq
        .sort
    end

    def actual_workflow_roots
      return [] unless receipts_root.directory?

      receipts_root.children.filter_map do |path|
        if path.directory?
          path.basename.to_s
        elsif path.file? && path.extname == ".rb"
          path.basename(".rb").to_s
        end
      end.uniq.sort
    end

    def unknown_workflow_roots
      actual_workflow_roots - registry.keys.sort
    end

    def active_workflows
      registry.keys.select do |workflow|
        entry = registry.fetch(workflow)
        root.join(entry.fetch(:facade_path)).file? || root.join(entry.fetch(:private_root)).directory?
      end.sort
    end

    def private_files
      active_workflows.flat_map do |workflow|
        root.glob("#{registry.fetch(workflow).fetch(:private_root)}/**/*.rb").sort.map do |path|
          [ workflow, path ]
        end
      end
    end

    def facade_path(workflow)
      root.join(registry.fetch(workflow).fetch(:facade_path))
    end

    def facade_constant(workflow)
      registry.fetch(workflow).fetch(:namespace)
    end

    def owned_constants(workflow)
      @owned_constants ||= {}
      @owned_constants[workflow] ||= begin
        facade = facade_path(workflow)
        child_paths = private_files.filter_map { |owner, path| path if owner == workflow }
        definitions = ([ facade ] + child_paths).select(&:file?).flat_map do |path|
          analysis_for(path).definitions.map(&:constant_name)
        end
        expected = child_paths.filter_map { |path| expected_constant_path(path) }
        namespace = facade_constant(workflow)

        (definitions + expected).compact.uniq.select do |constant|
          constant.start_with?("#{namespace}::")
        end.sort
      end
    end

    def private_constant_owners
      @private_constant_owners ||= active_workflows.each_with_object({}) do |workflow, owners|
        public_constants = registry.fetch(workflow).fetch(:public_constants)
        owned_constants(workflow).each do |constant|
          next if public_constants.include?(constant)

          owners[constant] = workflow
        end
      end
    end

    def public_constant_owners
      @public_constant_owners ||= active_workflows.each_with_object({}) do |workflow, owners|
        registry.fetch(workflow).fetch(:public_constants).each do |constant|
          owners[constant] = workflow
        end
      end
    end

    def resolve_workflow_reference(reference)
      candidates = reference_candidates(reference)
      candidates.each do |constant_name|
        if (private_owner = private_constant_owners[constant_name])
          return resolved_reference(constant_name, private_owner, :private)
        end
        if (public_owner = public_constant_owners[constant_name])
          return resolved_reference(constant_name, public_owner, :public_constant)
        end
        facade_owner = active_workflows.find do |workflow|
          constant_name == facade_constant(workflow)
        end
        return resolved_reference(constant_name, facade_owner, :facade) if facade_owner
      end

      candidates.each do |constant_name|
        if (private_owner = matching_owner(constant_name, private_constant_owners))
          return resolved_reference(constant_name, private_owner, :private)
        end
        if (public_owner = matching_owner(constant_name, public_constant_owners))
          return resolved_reference(constant_name, public_owner, :public_constant)
        end
      end
      nil
    end

    def resolved_reference(constant_name, target_workflow, visibility)
      ResolvedReference.new(
        constant_name: constant_name,
        target_workflow: target_workflow,
        visibility: visibility
      )
    end

    def matching_owner(constant_name, owners)
      matching_constant = owners.keys.select do |owned_constant|
        constant_name == owned_constant || constant_name.start_with?("#{owned_constant}::")
      end.max_by(&:length)

      owners[matching_constant] if matching_constant
    end

    def reference_candidates(reference)
      return [ reference.constant_name ] if reference.absolute

      scopes = reference.lexical_namespace.to_s.split("::")
      lexical = scopes.length.downto(1).map do |length|
        "#{scopes.first(length).join("::")}::#{reference.constant_name}"
      end
      (lexical + [ reference.constant_name ]).uniq
    end

    def allowed_reference?(source_path, source_workflow, resolved)
      return false if specialist_source?(source_path)
      return true if source_workflow == resolved.target_workflow

      if source_workflow
        allowed_targets = registry.fetch(source_workflow).fetch(:allowed_workflow_facades)
        return allowed_targets.include?(resolved.target_workflow) && public_visibility?(resolved.visibility)
      end

      public_visibility?(resolved.visibility)
    end

    def public_visibility?(visibility)
      %i[facade public_constant].include?(visibility)
    end

    def violation_rule(source_path, source_workflow, resolved)
      return :specialist_reverse_dependency if specialist_source?(source_path)
      return :private_implementation if resolved.visibility == :private
      return :forbidden_workflow_dependency if source_workflow

      :external_private_dependency
    end

    def workflow_for_source(source_path)
      active_workflows.find do |workflow|
        entry = registry.fetch(workflow)
        source_path == entry.fetch(:facade_path) ||
          source_path.start_with?("#{entry.fetch(:private_root)}/")
      end
    end

    def specialist_source?(source_path)
      SPECIALIST_FACADE_PATHS.include?(source_path) || SPECIALIST_SOURCE_ROOTS.any? do |source_root|
        source_path.start_with?("#{source_root}/")
      end
    end

    def analysis_for(path)
      source_analysis[path.to_s] ||= begin
        source_path = relative_path(path)
        if path.to_s.end_with?(".erb")
          compiled = ActionView::Template::Handlers::ERB.erb_implementation.new(path.read, trim: true).src
          ServiceLayerBoundary::SourceAnalyzer.new(source_path: source_path, line_offset: -1)
            .analyze("def __receipt_workflow_boundary_template__\n#{compiled}\nend")
        else
          ServiceLayerBoundary::SourceAnalyzer.new(source_path: source_path).analyze(path.read)
        end
      end
    end

    def relative_path(path)
      Pathname(path).relative_path_from(root).to_s
    end

    def expected_constant_path(path)
      constant_path_resolver.call(Pathname(path))
    end

    def default_constant_path(path)
      relative = Pathname(path).relative_path_from(services_root).sub_ext("").to_s
      ActiveSupport::Inflector.camelize(relative)
    end

    def entry_issues(workflow, entry)
      missing = REQUIRED_REGISTRY_KEYS - entry.keys
      return [ "#{workflow}: missing registry keys: #{missing.join(", ")}" ] if missing.any?

      issues = []
      expected_namespace = "Receipts::#{ActiveSupport::Inflector.camelize(workflow)}"
      expected_facade = "app/services/receipts/#{workflow}.rb"
      expected_private_root = "app/services/receipts/#{workflow}"
      issues << "#{workflow}: namespace must be #{expected_namespace}" unless entry.fetch(:namespace) == expected_namespace
      issues << "#{workflow}: facade_path must be #{expected_facade}" unless entry.fetch(:facade_path) == expected_facade
      issues << "#{workflow}: private_root must be #{expected_private_root}" unless entry.fetch(:private_root) == expected_private_root

      unknown_dependencies = entry.fetch(:allowed_workflow_facades).map(&:to_s) - registry.keys
      if unknown_dependencies.any?
        issues << "#{workflow}: unknown allowed workflow facades: #{unknown_dependencies.sort.join(", ")}"
      end

      if active_workflows.include?(workflow) && !facade_path(workflow).file?
        issues << "#{workflow}: missing workflow facade: #{entry.fetch(:facade_path)}"
      end

      entry.fetch(:public_constants).each do |constant|
        unless constant.start_with?("#{entry.fetch(:namespace)}::")
          issues << "#{workflow}: public constant is outside workflow namespace: #{constant}"
        end
      end
      issues
    end

    def facade_catalog_issues(workflow)
      path = facade_path(workflow)
      return [] unless path.file?

      expected = facade_constant(workflow)
      definitions = analysis_for(path).definitions.map(&:constant_name)
      return [] if definitions.include?(expected)

      [ "#{relative_path(path)}: expected #{expected}, defined #{definitions.sort.join(", ")}" ]
    end

    def private_catalog_issues(workflow)
      private_files.filter_map do |owner, path|
        next unless owner == workflow

        expected = expected_constant_path(path)
        relative = relative_path(path)
        if expected.blank?
          "#{relative}: Zeitwerk has no expected constant path"
        elsif !analysis_for(path).definitions.map(&:constant_name).include?(expected)
          definitions = analysis_for(path).definitions.map(&:constant_name).sort
          "#{relative}: expected #{expected}, defined #{definitions.join(", ")}"
        end
      end
    end

    def public_constant_issues
      active_workflows.flat_map do |workflow|
        registry.fetch(workflow).fetch(:public_constants).filter_map do |constant|
          unless owned_constants(workflow).include?(constant)
            "#{workflow}: public constant is not defined by its facade/private root: #{constant}"
          end
        end
      end
    end
  end
end
