require "pathname"
require "prism"

module ApplicationStructureBoundary
  ROOT_SCAN_GLOBS = %w[
    app/**/*.rb
    config/**/*.rb
    lib/**/*.rb
    lib/**/*.rake
  ].freeze
  STATUS_SCAN_GLOBS = %w[
    app/controllers/**/*.rb
    app/jobs/**/*.rb
    app/models/**/*.rb
    app/services/**/*.rb
  ].freeze

  Call = Data.define(:source_path, :line, :receiver_constant, :receiver_source, :method_name, :source)
  StatusWrite = Data.define(:source_path, :line, :record_type, :receiver_source, :method_name, :attributes)
  Issue = Data.define(:source_path, :line, :message)

  class RubyCallAnalyzer
    STATUS_MUTATION_METHODS = %i[
      new
      create
      create!
      update
      update!
      update_all
      update_column
      update_columns
      update_attribute
      update_attribute!
      assign_attributes
      attributes=
      status=
      stage=
      write_attribute
      write_attributes
      []=
    ].freeze
    DYNAMIC_DISPATCH_METHODS = %i[public_send send __send__].freeze

    attr_reader :calls, :status_writes, :issues

    def initialize(source_path:)
      @source_path = source_path
      @calls = []
      @status_writes = []
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

      record_call(node) if node.is_a?(Prism::CallNode)
      node.compact_child_nodes.each { |child| walk(child) }
    end

    def record_call(node)
      receiver_source = node.receiver&.location&.slice
      calls << Call.new(
        source_path: source_path,
        line: node.location.start_line,
        receiver_constant: constant_name(node.receiver),
        receiver_source: receiver_source,
        method_name: node.name,
        source: node.location.slice
      )

      status_write = build_status_write(node, receiver_source)
      status_writes << status_write if status_write
    end

    def constant_name(node)
      return unless node.respond_to?(:full_name)

      node.full_name.to_s.delete_prefix("::")
    rescue Prism::DynamicPartsInConstantPathError
      nil
    end

    def build_status_write(node, receiver_source)
      method_name = effective_method_name(node)
      return unless STATUS_MUTATION_METHODS.include?(method_name)

      attributes = status_attributes(node, method_name)
      return if attributes.empty?

      record_type = status_record_type(receiver_source)
      return unless record_type

      StatusWrite.new(
        source_path: source_path,
        line: node.location.start_line,
        record_type: record_type,
        receiver_source: receiver_source,
        method_name: method_name,
        attributes: attributes
      )
    end

    def status_attributes(node, method_name)
      return [ :status ] if method_name == :status=
      return [ :stage ] if method_name == :stage=
      if %i[write_attribute []=].include?(method_name)
        attribute = static_attribute_argument(node)
        return [ attribute ] if %i[status stage].include?(attribute)
      end

      arguments = node.arguments&.location&.slice.to_s
      attributes = []
      attributes << :status if arguments.match?(/(?:\bstatus\s*:|:status\b|["']status["']\s*=>)/)
      attributes << :stage if arguments.match?(/(?:\bstage\s*:|:stage\b|["']stage["']\s*=>)/)
      attributes
    end

    def effective_method_name(node)
      return node.name unless DYNAMIC_DISPATCH_METHODS.include?(node.name)

      static_symbol_or_string(node.arguments&.arguments&.first)&.to_sym || node.name
    end

    def static_attribute_argument(node)
      arguments = node.arguments&.arguments.to_a
      index = DYNAMIC_DISPATCH_METHODS.include?(node.name) ? 1 : 0
      static_symbol_or_string(arguments[index])&.to_sym
    end

    def static_symbol_or_string(node)
      return unless node.is_a?(Prism::StringNode) || node.is_a?(Prism::SymbolNode)

      node.unescaped.to_s
    end

    def status_record_type(receiver_source)
      normalized = receiver_source.to_s.delete("@_").downcase
      return model_record_type if normalized == "self"
      return :analysis_run if normalized.include?("receiptanalysisrun") || normalized.include?("receiptanalysisruns")
      return :analysis_run if normalized.match?(/(?:\A|\.)run\z/) || normalized.end_with?("lockedrun")
      return :receipt if normalized == "receipt" || normalized.end_with?(".receipts")

      nil
    end

    def model_record_type
      return :receipt if source_path == "app/models/receipt.rb"

      :analysis_run if source_path == "app/models/receipt_analysis_run.rb"
    end
  end

  class Scanner
    REQUIRED_ROOT_KEYS = %i[
      constant
      role
      owner
      external_methods
      declared_singleton_methods
      declared_instance_methods
      constructible
      remove_in_loop
    ].freeze
    ALLOWED_ROLES = %i[
      public_facade
      platform_contract
      domain_policy
      legacy_workflow
      legacy_query
      legacy_form
      legacy_policy
    ].freeze

    attr_reader :root, :registry

    def initialize(root:, registry:, constant_path_resolver: nil)
      @root = Pathname(root)
      @registry = registry.transform_keys(&:to_s)
      @constant_path_resolver = constant_path_resolver || method(:default_constant_path)
      @analysis = {}
    end

    def actual_root_service_files
      root.glob("app/services/*.rb").select(&:file?).map { |path| path.basename.to_s }.sort
    end

    def registry_issues
      issues = []
      (actual_root_service_files - registry.keys.sort).each do |file|
        issues << "unregistered root service: #{file}"
      end
      (registry.keys.sort - actual_root_service_files).each do |file|
        issues << "stale root service registry entry: #{file}"
      end

      registry.each do |file, metadata|
        issues.concat(metadata_issues(file, metadata))
      end
      issues
    end

    def external_api_issues
      registry.filter_map do |file, metadata|
        expected = metadata.fetch(:external_methods).map(&:to_sym).sort
        actual = external_methods_for(file, metadata.fetch(:constant))
        next if actual == expected

        "#{file}: external API mismatch; expected=#{expected.inspect} actual=#{actual.inspect}"
      end
    end

    def declared_api_issues
      registry.flat_map do |file, metadata|
        constant = metadata.fetch(:constant).safe_constantize
        next [ "#{file}: registered constant is not loadable: #{metadata.fetch(:constant)}" ] unless constant

        issues = []
        expected_singleton = metadata.fetch(:declared_singleton_methods).map(&:to_sym).sort
        actual_singleton = constant.singleton_class.public_instance_methods(false).map(&:to_sym).sort
        unless actual_singleton == expected_singleton
          issues << "#{file}: singleton API mismatch; expected=#{expected_singleton.inspect} actual=#{actual_singleton.inspect}"
        end

        expected_instance = metadata.fetch(:declared_instance_methods).map(&:to_sym).sort
        actual_instance = constant.is_a?(Class) ? constant.public_instance_methods(false).map(&:to_sym).sort : []
        unless actual_instance == expected_instance
          issues << "#{file}: instance API mismatch; expected=#{expected_instance.inspect} actual=#{actual_instance.inspect}"
        end

        expected_constructible = metadata.fetch(:constructible)
        actual_constructible = constant.is_a?(Class) && constant.respond_to?(:new)
        unless actual_constructible == expected_constructible
          issues << "#{file}: constructible mismatch; expected=#{expected_constructible} actual=#{actual_constructible}"
        end
        issues
      end
    end

    def external_methods_for(file, constant)
      production_files.flat_map do |path|
        next [] if relative_path(path) == "app/services/#{file}"

        analysis_for(path).calls.filter_map do |call|
          call.method_name if call.receiver_constant == constant
        end
      end.uniq.sort
    end

    def status_writes
      status_files.flat_map { |path| analysis_for(path).status_writes }
        .uniq
        .sort_by { |write| [ write.source_path, write.line, write.record_type.to_s, write.method_name.to_s ] }
    end

    def analysis_issues
      (production_files + status_files).uniq.flat_map { |path| analysis_for(path).issues }.uniq
    end

    private

    attr_reader :constant_path_resolver, :analysis

    def production_files
      ROOT_SCAN_GLOBS.flat_map { |glob| root.glob(glob) }.select(&:file?).uniq.sort
    end

    def status_files
      STATUS_SCAN_GLOBS.flat_map { |glob| root.glob(glob) }.select(&:file?).uniq.sort
    end

    def analysis_for(path)
      analysis[path.to_s] ||= RubyCallAnalyzer.new(source_path: relative_path(path)).analyze(path.read)
    end

    def relative_path(path)
      Pathname(path).relative_path_from(root).to_s
    end

    def metadata_issues(file, metadata)
      missing = REQUIRED_ROOT_KEYS - metadata.keys
      return [ "#{file}: missing metadata keys: #{missing.join(", ")}" ] if missing.any?

      issues = []
      role = metadata.fetch(:role)
      issues << "#{file}: unknown role #{role.inspect}" unless ALLOWED_ROLES.include?(role)

      expected_constant = constant_path_resolver.call(root.join("app/services", file))
      unless metadata.fetch(:constant) == expected_constant
        issues << "#{file}: expected Zeitwerk constant #{expected_constant}, registered #{metadata.fetch(:constant)}"
      end
      issues << "#{file}: owner is required" if metadata.fetch(:owner).blank?

      removal_loop = metadata.fetch(:remove_in_loop)
      if role.to_s.start_with?("legacy_")
        unless removal_loop.is_a?(Integer) && removal_loop.between?(4, 22)
          issues << "#{file}: legacy root requires remove_in_loop 4..22"
        end
      elsif removal_loop.present?
        issues << "#{file}: non-legacy root must not set remove_in_loop"
      end
      issues
    end

    def default_constant_path(path)
      ActiveSupport::Inflector.camelize(Pathname(path).basename(".rb").to_s)
    end
  end
end
