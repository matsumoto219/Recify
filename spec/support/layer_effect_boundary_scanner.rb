require "pathname"
require "prism"

module LayerEffectBoundary
  Effect = Data.define(:source_path, :line, :layer, :effect, :receiver_constant, :receiver_source, :method_name)
  FacadeAlias = Data.define(:source_path, :line, :target_source, :receiver_constant)
  Issue = Data.define(:source_path, :line, :message)

  class Scanner
    LAYER_GLOBS = {
      query: "app/queries/**/*.rb",
      form: "app/forms/**/*.rb"
    }.freeze
    DB_MUTATION_METHODS = %i[
      save
      save!
      create
      create!
      update
      update!
      update_all
      update_column
      update_columns
      update_attribute
      update_attribute!
      destroy
      destroy!
      destroy_all
      destroy_by
      delete_by
      delete_all
      touch
      touch!
      touch_all
      increment!
      decrement!
      insert
      insert_all
      insert_all!
      upsert
      upsert_all
      toggle!
      create_or_find_by
      create_or_find_by!
      find_or_create_by
      find_or_create_by!
    ].freeze
    ASYNC_METHODS = %i[
      perform_later
      perform_now
      enqueue
      enqueue_at
      deliver_later
      deliver_now
    ].freeze
    PROVIDER_CALLS = {
      "ReceiptOcrService" => %i[call],
      "ReceiptAiEnrichmentService" => %i[call],
      "Ocr::Client" => %i[call],
      "Ai::Client" => %i[call]
    }.freeze
    AUDIT_CALLS = {
      "AuditLogs" => %i[record_admin_action! record_system_action!],
      "SecurityEvents" => %i[
        record!
        record_admin_audit_burst!
        record_csrf_failure!
        record_external_service_failure!
        record_invalid_upload!
        record_rate_limit!
        record_request_detections!
        record_suspicious_error!
      ]
    }.freeze
    CUSTOM_MUTATION_CALLS = {
      "Admin::Operations" => %i[
        archive_announcement
        create_announcement
        publish_announcement
        update_announcement
        update_contact_request_status
        update_security_event_status
      ],
      "Receipts::Processing" => %i[
        cancel
        claim_stage
        cleanup_expired
        cleanup_stale
        copy_retry_snapshots
        enqueue
        fail
        finish_stage
        mark_processing!
        record_ai_input
        record_ai_normalized_result
        record_ai_result
        record_build_params_snapshot
        record_final_result
        record_finalize_decision
        record_ocr_response_artifact
        record_ocr_result
        record_ocr_snapshot
        run_ai
        run_finalize
        run_ocr
        start
        start_stage
        succeed
        supersede
      ],
      "Receipts::Editing" => %i[
        apply_amount_result!
        create_manual
        update_manual
      ],
      "Receipts::Uploads" => %i[batch single],
      "Storage" => %i[purge_attachment purge_receipt_images],
      "SystemOperations" => %i[
        execute_ip_access_operation
        execute_receipt_analysis_cleanup
        execute_receipt_analysis_retry
        execute_receipt_moderation_operation
        execute_user_operation
        reset_setting
        update_setting
        update_user_limit
      ],
      "Usage" => %i[
        consume_ai_job!
        consume_batch_upload!
        consume_manual_receipt!
        consume_ocr_job!
        consume_receipt_upload!
        consume_retry_operation!
      ]
    }.freeze
    ADMIN_MUTATION_METHODS = %i[
      save
      save!
      assign_attributes
      create
      create!
      update
      update!
      update_columns
      destroy
      destroy!
      status=
    ].freeze
    SERVICE_RENDER_METHODS = %i[render render_to_string].freeze
    DYNAMIC_DISPATCH_METHODS = %i[public_send send __send__].freeze
    PROTECTED_FACADE_CONSTANTS = (
      PROVIDER_CALLS.keys + AUDIT_CALLS.keys + CUSTOM_MUTATION_CALLS.keys
    ).uniq.freeze
    HIGH_RISK_FACADE_CONSTANTS = %w[Admin::Operations SystemOperations].freeze

    attr_reader :root

    def initialize(root:)
      @root = Pathname(root)
      @analysis = {}
    end

    def layer_effects
      LAYER_GLOBS.flat_map do |layer, glob|
        root.glob(glob).select(&:file?).flat_map do |path|
          call_effects = calls_for(path).filter_map { |call| effect_for(call, layer) }
          alias_effects = aliases_for(path).filter_map do |facade_alias|
            next unless PROTECTED_FACADE_CONSTANTS.include?(facade_alias.receiver_constant)

            alias_effect_record(facade_alias, layer)
          end
          call_effects + alias_effects
        end
      end.sort_by { |effect| [ effect.source_path, effect.line, effect.effect.to_s ] }
    end

    def high_risk_facade_aliases
      high_risk_caller_files.flat_map do |path|
        aliases_for(path).filter_map do |facade_alias|
          next unless HIGH_RISK_FACADE_CONSTANTS.include?(facade_alias.receiver_constant)

          alias_effect_record(facade_alias, :admin_controller)
        end
      end.sort_by { |effect| [ effect.source_path, effect.line, effect.receiver_constant ] }
    end

    def db_mutations_in_files_referencing(pattern, receiver_pattern: nil, globs: "app/**/*.rb")
      paths_for(globs).flat_map do |path|
        next [] unless path.read.match?(pattern)

        calls_for(path).filter_map do |call|
          method_name = effective_method_name(call)
          next unless DB_MUTATION_METHODS.include?(method_name)
          next if receiver_pattern && !call.fetch(:receiver_source).to_s.match?(receiver_pattern)

          effect_record(call, :architecture, :db_write, method_name: method_name)
        end
      end.sort_by { |effect| [ effect.source_path, effect.line, effect.method_name ] }
    end

    def admin_controller_mutations
      root.glob("app/controllers/admin/**/*.rb").select(&:file?).flat_map do |path|
        calls_for(path).filter_map do |call|
          next unless ADMIN_MUTATION_METHODS.include?(call.fetch(:method_name))

          effect_record(call, :admin_controller, :db_write)
        end
      end.sort_by { |effect| [ effect.source_path, effect.line, effect.method_name.to_s ] }
    end

    def service_render_calls
      root.glob("app/services/**/*.rb").select(&:file?).flat_map do |path|
        calls_for(path).filter_map do |call|
          next unless SERVICE_RENDER_METHODS.include?(call.fetch(:method_name))

          effect_record(call, :service, :html_render)
        end
      end.sort_by { |effect| [ effect.source_path, effect.line, effect.method_name.to_s ] }
    end

    def constant_calls(constant, globs:)
      Array(globs).flat_map { |glob| root.glob(glob) }.select(&:file?).uniq.flat_map do |path|
        calls_for(path).filter_map do |call|
          effect_record(call, :production, :constant_call) if call.fetch(:receiver_constant) == constant
        end
      end.sort_by { |effect| [ effect.source_path, effect.line, effect.method_name.to_s ] }
    end

    def analysis_issues
      target_files.flat_map { |path| analysis_for(path).fetch(:issues) }.uniq
    end

    private

    attr_reader :analysis

    def target_files
      globs = LAYER_GLOBS.values + %w[
        app/controllers/admin/**/*.rb
        app/services/**/*.rb
      ]
      globs.flat_map { |glob| root.glob(glob) }.select(&:file?).uniq.sort
    end

    def effect_for(call, layer)
      method_name = effective_method_name(call)
      return effect_record(call, layer, :db_write, method_name:) if DB_MUTATION_METHODS.include?(method_name)
      return effect_record(call, layer, :async, method_name:) if ASYNC_METHODS.include?(method_name)

      receiver_constant = call.fetch(:receiver_constant)
      if PROVIDER_CALLS.fetch(receiver_constant, []).include?(method_name)
        return effect_record(call, layer, :provider, method_name:)
      end
      if AUDIT_CALLS.fetch(receiver_constant, []).include?(method_name)
        return effect_record(call, layer, :audit, method_name:)
      end

      if CUSTOM_MUTATION_CALLS.fetch(receiver_constant, []).include?(method_name)
        effect_record(call, layer, :workflow_mutation, method_name:)
      end
    end

    def effect_record(call, layer, effect, method_name: call.fetch(:method_name))
      Effect.new(
        source_path: call.fetch(:source_path),
        line: call.fetch(:line),
        layer: layer,
        effect: effect,
        receiver_constant: call.fetch(:receiver_constant),
        receiver_source: call.fetch(:receiver_source),
        method_name: method_name
      )
    end

    def alias_effect_record(facade_alias, layer)
      Effect.new(
        source_path: facade_alias.source_path,
        line: facade_alias.line,
        layer: layer,
        effect: :facade_alias,
        receiver_constant: facade_alias.receiver_constant,
        receiver_source: facade_alias.target_source,
        method_name: :alias
      )
    end

    def effective_method_name(call)
      call.fetch(:dispatched_method_name) || call.fetch(:method_name)
    end

    def calls_for(path)
      analysis_for(path).fetch(:calls)
    end

    def aliases_for(path)
      analysis_for(path).fetch(:aliases)
    end

    def analysis_for(path)
      analysis[path.to_s] ||= analyze(path)
    end

    def analyze(path)
      source_path = path.relative_path_from(root).to_s
      result = Prism.parse(path.read)
      issues = result.errors.map do |error|
        Issue.new(source_path: source_path, line: error.location.start_line, message: error.message)
      end
      return { calls: [], aliases: [], issues: issues } unless result.success?

      calls = []
      aliases = []
      walk = lambda do |node|
        if node.is_a?(Prism::CallNode)
          calls << {
            source_path: source_path,
            line: node.location.start_line,
            receiver_constant: constant_name(node.receiver),
            receiver_source: node.receiver&.location&.slice,
            method_name: node.name,
            dispatched_method_name: static_dispatched_method_name(node)
          }
        end
        facade_alias = build_facade_alias(node, source_path)
        aliases << facade_alias if facade_alias
        dynamic_facade_reference = build_dynamic_facade_reference(node, source_path)
        aliases << dynamic_facade_reference if dynamic_facade_reference
        node.compact_child_nodes.each { |child| walk.call(child) }
      end
      walk.call(result.value)
      { calls: calls, aliases: aliases, issues: issues }
    end

    def static_dispatched_method_name(node)
      return unless DYNAMIC_DISPATCH_METHODS.include?(node.name)

      static_symbol_or_string(node.arguments&.arguments&.first)&.to_sym
    end

    def static_symbol_or_string(node)
      return unless node.is_a?(Prism::StringNode) || node.is_a?(Prism::SymbolNode)

      node.unescaped.to_s
    end

    def build_facade_alias(node, source_path)
      return unless assignment_node?(node)

      receiver_constant = constant_name(node.value)
      return unless receiver_constant

      FacadeAlias.new(
        source_path: source_path,
        line: node.location.start_line,
        target_source: assignment_target_source(node),
        receiver_constant: receiver_constant
      )
    end

    def build_dynamic_facade_reference(node, source_path)
      return unless node.is_a?(Prism::CallNode)

      receiver_constant = dynamic_constant_name(node)
      return unless receiver_constant

      FacadeAlias.new(
        source_path: source_path,
        line: node.location.start_line,
        target_source: node.location.slice,
        receiver_constant: receiver_constant.delete_prefix("::")
      )
    end

    def dynamic_constant_name(node)
      if %i[constantize safe_constantize].include?(node.name)
        return static_constant_literal(node.receiver)
      end
      return unless node.name == :const_get

      name = static_constant_literal(node.arguments&.arguments&.first)
      return unless name
      return name if name.start_with?("::")

      receiver_name = constant_name(node.receiver)
      return name if receiver_name.blank? || receiver_name == "Object"

      "#{receiver_name}::#{name}"
    end

    def static_constant_literal(node)
      value = static_symbol_or_string(node)
      return unless value&.match?(/\A(?:::)?[A-Z][A-Za-z0-9]*(?:::[A-Z][A-Za-z0-9]*)*\z/)

      value
    end

    def assignment_node?(node)
      node.is_a?(Prism::LocalVariableWriteNode) ||
        node.is_a?(Prism::InstanceVariableWriteNode) ||
        node.is_a?(Prism::ClassVariableWriteNode) ||
        node.is_a?(Prism::GlobalVariableWriteNode) ||
        node.is_a?(Prism::ConstantWriteNode) ||
        node.is_a?(Prism::ConstantPathWriteNode)
    end

    def assignment_target_source(node)
      return node.target.location.slice if node.respond_to?(:target)
      return node.name.to_s if node.respond_to?(:name)

      node.location.slice.to_s.split("=", 2).first.to_s.strip
    end

    def high_risk_caller_files
      %w[
        app/controllers/**/*.rb
        app/jobs/**/*.rb
        app/models/**/*.rb
      ].flat_map { |glob| root.glob(glob) }.select(&:file?).uniq.sort
    end

    def paths_for(globs)
      Array(globs).flat_map { |glob| root.glob(glob) }.select(&:file?).uniq.sort
    end

    def constant_name(node)
      return unless node.respond_to?(:full_name)

      node.full_name.to_s.delete_prefix("::")
    rescue Prism::DynamicPartsInConstantPathError
      nil
    end
  end
end
