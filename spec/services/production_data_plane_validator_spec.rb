# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProductionDataPlaneValidator do
  before do
    LegalDocuments::Sync.call
  end

  let(:rails_config) do
    ActiveSupport::OrderedOptions.new.tap do |config|
      config.active_job = ActiveSupport::OrderedOptions.new
      config.active_job.queue_adapter = :solid_queue
      config.solid_queue = ActiveSupport::OrderedOptions.new
      config.solid_queue.connects_to = { database: { writing: :queue } }
      config.cache_store = :solid_cache_store
      config.active_storage = ActiveSupport::OrderedOptions.new
      config.active_storage.service = :local
    end
  end

  let(:database_configurations) do
    {
      "production" => {
        "primary" => { "adapter" => "postgresql", "database" => "recify_production" },
        "cache" => {
          "adapter" => "postgresql",
          "database" => "recify_production_cache",
          "migrations_paths" => "db/cache_migrate"
        },
        "queue" => {
          "adapter" => "postgresql",
          "database" => "recify_production_queue",
          "migrations_paths" => "db/queue_migrate"
        },
        "cable" => {
          "adapter" => "postgresql",
          "database" => "recify_production_cable",
          "migrations_paths" => "db/cable_migrate"
        }
      }
    }
  end

  let(:queue_config) do
    {
      "production" => {
        "workers" => [
          { "queues" => "default" },
          { "queues" => "receipt_ocr" },
          { "queues" => "receipt_ai" },
          { "queues" => "receipt_finalize" }
        ]
      }
    }
  end

  let(:cable_config) do
    {
      "production" => {
        "adapter" => "solid_cable",
        "connects_to" => { "database" => { "writing" => "cable" } }
      }
    }
  end

  let(:cache_config) do
    { "production" => { "database" => "cache" } }
  end

  let(:storage_config) do
    {
      "local" => {
        "service" => "Disk",
        "root" => "/rails/storage"
      }
    }
  end

  let(:recurring_config) do
    {
      "production" => described_class::REQUIRED_DRY_RUN_RECURRING_TASKS.to_h do |task_name|
        [ task_name, { "class" => "ExampleCleanupJob", "args" => [ { "dry_run" => true, "limit" => 100 } ] } ]
      end.merge(
        "clear_solid_queue_finished_jobs" => {
          "command" => "SolidQueue::Job.clear_finished_in_batches(sleep_between_batches: 0.3)"
        }
      )
    }
  end

  let(:deploy_config) do
    { "volumes" => [ "recify_storage:/rails/storage" ] }
  end

  let(:root_path) { Rails.root }

  def validator(**overrides)
    described_class.new(
      rails_config: rails_config,
      database_configurations: database_configurations,
      root_path: root_path,
      queue_config: queue_config,
      cable_config: cable_config,
      cache_config: cache_config,
      storage_config: storage_config,
      recurring_config: recurring_config,
      deploy_config: deploy_config,
      **overrides
    )
  end

  it "現在の本番データ基盤構成を有効として扱う" do
    result = validator.call

    expect(result).to be_success
  end

  it "legal_documentsのDB同期検証を含める" do
    legal_documents_validator = class_double(
      ProductionLegalDocumentsValidator,
      call: ProductionLegalDocumentsValidator::Result.new(
        missing_items: [ "legal_documents.database: DB current terms/ja count is 0" ]
      )
    )

    result = validator(legal_documents_validator: legal_documents_validator).call

    aggregate_failures do
      expect(result.missing_items).to include("legal_documents.database: DB current terms/ja count is 0")
      expect(legal_documents_validator).to have_received(:call).with(database: true)
    end
  end

  it "production primary/cache/queue/cable DB role不足を検出する" do
    configs = database_configurations.deep_dup
    configs["production"].delete("queue")

    expect do
      validator(database_configurations: configs).validate!
    end.to raise_error(described_class::ValidationError) { |error|
      expect(error.message).to include("database.production.queue")
    }
  end

  it "Solid Queueの必須queue不足を検出する" do
    config = queue_config.deep_dup
    config["production"]["workers"].reject! { |worker| worker["queues"] == "receipt_ai" }

    result = validator(queue_config: config).call

    expect(result.missing_items).to include("queue.production.receipt_ai")
  end

  it "ActiveStorage local volumeのdeploy受け皿不足を検出する" do
    result = validator(deploy_config: { "volumes" => [] }).call

    expect(result.missing_items).to include("deploy.volume.rails_storage")
  end

  it "cleanup recurring taskがdry-runでない場合に検出する" do
    config = recurring_config.deep_dup
    config["production"]["orphan_blob_cleanup_dry_run"]["args"] = [ { "dry_run" => false, "limit" => 100 } ]

    result = validator(recurring_config: config).call

    expect(result.missing_items).to include("recurring.production.orphan_blob_cleanup_dry_run.dry_run")
  end

  it "secret値をエラーメッセージへ含めない" do
    configs = database_configurations.deep_dup
    configs["production"]["queue"]["password"] = "database-secret-value"
    configs["production"].delete("cable")

    expect do
      validator(database_configurations: configs).validate!
    end.to raise_error(described_class::ValidationError) { |error|
      expect(error.message).to include("database.production.cable")
      expect(error.message).not_to include("database-secret-value")
    }
  end
end
