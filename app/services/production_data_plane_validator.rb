# frozen_string_literal: true

require_relative "production_legal_documents_validator"

require "erb"
require "yaml"

class ProductionDataPlaneValidator
  ValidationError = Class.new(StandardError)

  Result = Struct.new(:missing_items, keyword_init: true) do
    def success?
      missing_items.empty?
    end
  end

  REQUIRED_DATABASE_ROLES = %w[primary cache queue cable].freeze
  REQUIRED_SCHEMA_FILES = {
    "primary" => "db/schema.rb",
    "cache" => "db/cache_schema.rb",
    "queue" => "db/queue_schema.rb",
    "cable" => "db/cable_schema.rb"
  }.freeze
  REQUIRED_QUEUE_NAMES = %w[default receipt_ocr receipt_ai receipt_finalize].freeze
  REQUIRED_DRY_RUN_RECURRING_TASKS = %w[
    orphan_blob_cleanup_dry_run
    receipt_image_purge_dry_run
    receipt_analysis_run_stale_cleanup_dry_run
    receipt_analysis_run_retention_cleanup_dry_run
    user_session_retention_cleanup_dry_run
    contact_request_retention_cleanup_dry_run
    audit_log_retention_cleanup_dry_run
    security_event_retention_cleanup_dry_run
  ].freeze

  class << self
    def validate!(...)
      new(...).validate!
    end

    def call(...)
      new(...).call
    end
  end

  def initialize(
    rails_config: Rails.application.config,
    database_configurations: ActiveRecord::Base.configurations,
    root_path: Rails.root,
    queue_config: nil,
    cable_config: nil,
    cache_config: nil,
    storage_config: nil,
    recurring_config: nil,
    deploy_config: nil,
    legal_documents_validator: ProductionLegalDocumentsValidator
  )
    @rails_config = rails_config
    @database_configurations = database_configurations
    @root_path = Pathname(root_path)
    @queue_config = queue_config
    @cable_config = cable_config
    @cache_config = cache_config
    @storage_config = storage_config
    @recurring_config = recurring_config
    @deploy_config = deploy_config
    @legal_documents_validator = legal_documents_validator
  end

  def validate!
    result = call
    return result if result.success?

    raise ValidationError, error_message(result.missing_items)
  end

  def call
    Result.new(missing_items: missing_items.uniq.sort)
  end

  private

  attr_reader :rails_config, :database_configurations, :root_path

  def missing_items
    missing = []
    missing += missing_database_items
    missing += missing_schema_files
    missing += missing_solid_queue_items
    missing += missing_solid_cable_items
    missing += missing_solid_cache_items
    missing += missing_active_storage_items
    missing += missing_recurring_items
    missing += missing_legal_document_database_items
    missing
  end

  def missing_legal_document_database_items
    legal_documents_validator.call(database: true).missing_items
  end

  def missing_database_items
    configs = production_database_configs

    REQUIRED_DATABASE_ROLES.flat_map do |role|
      config = configs[role]
      next [ "database.production.#{role}" ] if config.blank?

      missing = []
      missing << "database.production.#{role}.postgresql" unless config["adapter"].to_s == "postgresql"
      if role != "primary" && config["migrations_paths"].blank?
        missing << "database.production.#{role}.migrations_paths"
      end
      missing
    end
  end

  def missing_schema_files
    REQUIRED_SCHEMA_FILES.values.reject { |path| root_path.join(path).file? }.map { |path| "schema.#{path}" }
  end

  def missing_solid_queue_items
    missing = []
    missing << "active_job.queue_adapter.solid_queue" unless active_job_adapter == :solid_queue
    unless nested_value(rails_config.solid_queue.connects_to, :database, :writing).to_s == "queue"
      missing << "solid_queue.connects_to.queue"
    end

    queues = Array(production_section(queue_config)["workers"]).filter_map { |worker| worker["queues"].presence }
    missing + REQUIRED_QUEUE_NAMES.reject { |queue| queues.include?(queue) }.map { |queue| "queue.production.#{queue}" }
  end

  def missing_solid_cable_items
    production = production_section(cable_config)
    missing = []
    missing << "cable.production.solid_cable" unless production["adapter"].to_s == "solid_cable"
    unless nested_value(production["connects_to"], "database", "writing").to_s == "cable"
      missing << "cable.production.database.cable"
    end
    missing
  end

  def missing_solid_cache_items
    production = production_section(cache_config)
    missing = []
    missing << "cache_store.solid_cache_store" unless cache_store_name == :solid_cache_store
    missing << "cache.production.database.cache" unless production["database"].to_s == "cache"
    missing
  end

  def missing_active_storage_items
    missing = []
    missing << "active_storage.production.local" unless rails_config.active_storage.service.to_s == "local"
    missing << "storage.local.disk" unless local_storage_config["service"].to_s == "Disk"
    unless deploy_volumes.any? { |volume| volume.to_s.include?("/rails/storage") }
      missing << "deploy.volume.rails_storage"
    end
    missing
  end

  def missing_recurring_items
    production = production_section(recurring_config)
    missing = REQUIRED_DRY_RUN_RECURRING_TASKS.reject do |task_name|
      recurring_dry_run_task?(production[task_name])
    end.map { |task_name| "recurring.production.#{task_name}.dry_run" }

    clear_command = production.dig("clear_solid_queue_finished_jobs", "command").to_s
    unless clear_command.include?("SolidQueue::Job.clear_finished_in_batches")
      missing << "recurring.production.clear_solid_queue_finished_jobs"
    end

    missing
  end

  def production_database_configs
    if database_configurations.respond_to?(:configs_for)
      database_configurations.configs_for(env_name: "production").to_h do |config|
        [ config.name.to_s, config.configuration_hash.stringify_keys ]
      end
    else
      database_configurations.fetch("production", {}).transform_values { |config| config.stringify_keys }
    end
  end

  def active_job_adapter
    rails_config.active_job.queue_adapter.to_sym
  end

  def cache_store_name
    Array(rails_config.cache_store).first.to_sym
  end

  def local_storage_config
    storage_config.fetch("local", {})
  end

  def deploy_volumes
    Array(deploy_config["volumes"])
  end

  def recurring_dry_run_task?(task)
    return false if task.blank?

    Array(task["args"]).any? { |arg| arg.is_a?(Hash) && arg["dry_run"] == true }
  end

  def queue_config
    @queue_config ||= load_yaml("config/queue.yml")
  end

  def cable_config
    @cable_config ||= load_yaml("config/cable.yml")
  end

  def cache_config
    @cache_config ||= load_yaml("config/cache.yml")
  end

  def storage_config
    @storage_config ||= load_yaml("config/storage.yml")
  end

  def recurring_config
    @recurring_config ||= load_yaml("config/recurring.yml")
  end

  def deploy_config
    @deploy_config ||= load_yaml("config/deploy.yml")
  end

  def load_yaml(path)
    source = ERB.new(root_path.join(path).read).result
    YAML.safe_load(source, aliases: true) || {}
  end

  def production_section(config)
    config.fetch("production", {})
  end

  def nested_value(value, *keys)
    keys.reduce(value) do |current, key|
      if current.respond_to?(:[])
        current[key] || current[key.to_s] || current[key.to_sym]
      end
    end
  end

  def error_message(items)
    "Missing required production data-plane configuration: #{items.join(', ')}"
  end

  attr_reader :legal_documents_validator
end
