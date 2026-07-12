require "pathname"
require "prism"

module LayerEffectBoundary
  Effect = Data.define(:source_path, :line, :layer, :effect, :receiver_constant, :receiver_source, :method_name)
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
      delete_all
      touch
      touch!
      increment!
      decrement!
      insert
      insert_all
      upsert
      upsert_all
      toggle!
      find_or_create_by!
      find_or_initialize_by
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
      "ReceiptAnalysisRuns" => %i[
        cancel
        cleanup_expired
        cleanup_stale
        copy_retry_snapshots
        enqueue
        fail
        finish_stage
        record_ai_input
        record_ai_normalized_result
        record_ai_result
        record_build_params_snapshot
        record_final_result
        record_finalize_decision
        record_ocr_response_artifact
        record_ocr_result
        record_ocr_snapshot
        start
        start_stage
        succeed
        supersede
      ],
      "Storage" => %i[purge_attachment purge_receipt_images],
      "SystemOperations" => %i[
        execute_ip_access_operation
        execute_receipt_analysis_cleanup
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

    attr_reader :root

    def initialize(root:)
      @root = Pathname(root)
      @analysis = {}
    end

    def layer_effects
      LAYER_GLOBS.flat_map do |layer, glob|
        root.glob(glob).select(&:file?).flat_map do |path|
          calls_for(path).filter_map { |call| effect_for(call, layer) }
        end
      end.sort_by { |effect| [ effect.source_path, effect.line, effect.effect.to_s ] }
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
      method_name = call.fetch(:method_name)
      return effect_record(call, layer, :db_write) if DB_MUTATION_METHODS.include?(method_name)
      return effect_record(call, layer, :async) if ASYNC_METHODS.include?(method_name)

      receiver_constant = call.fetch(:receiver_constant)
      return effect_record(call, layer, :provider) if PROVIDER_CALLS.fetch(receiver_constant, []).include?(method_name)
      return effect_record(call, layer, :audit) if AUDIT_CALLS.fetch(receiver_constant, []).include?(method_name)

      effect_record(call, layer, :workflow_mutation) if CUSTOM_MUTATION_CALLS.fetch(receiver_constant, []).include?(method_name)
    end

    def effect_record(call, layer, effect)
      Effect.new(
        source_path: call.fetch(:source_path),
        line: call.fetch(:line),
        layer: layer,
        effect: effect,
        receiver_constant: call.fetch(:receiver_constant),
        receiver_source: call.fetch(:receiver_source),
        method_name: call.fetch(:method_name)
      )
    end

    def calls_for(path)
      analysis_for(path).fetch(:calls)
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
      return { calls: [], issues: issues } unless result.success?

      calls = []
      walk = lambda do |node|
        if node.is_a?(Prism::CallNode)
          calls << {
            source_path: source_path,
            line: node.location.start_line,
            receiver_constant: constant_name(node.receiver),
            receiver_source: node.receiver&.location&.slice,
            method_name: node.name
          }
        end
        node.compact_child_nodes.each { |child| walk.call(child) }
      end
      walk.call(result.value)
      { calls: calls, issues: issues }
    end

    def constant_name(node)
      return unless node.respond_to?(:full_name)

      node.full_name.to_s.delete_prefix("::")
    rescue Prism::DynamicPartsInConstantPathError
      nil
    end
  end
end
