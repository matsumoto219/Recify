# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "recify:env tasks" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("recify:env:validate")
  end

  let(:task) { Rake::Task["recify:env:validate"] }

  before do
    task.reenable
  end

  it "calls the production environment validator in strict mode" do
    allow(ProductionEnvValidator).to receive(:validate!).with(strict: true).and_return(
      ProductionEnvValidator::Result.new(missing_keys: [])
    )
    allow(ProductionDataPlaneValidator).to receive(:validate!).and_return(
      ProductionDataPlaneValidator::Result.new(missing_items: [])
    )

    expect { task.invoke }.to output(/Production environment and data-plane configuration is valid/).to_stdout

    expect(ProductionEnvValidator).to have_received(:validate!).with(strict: true)
    expect(ProductionDataPlaneValidator).to have_received(:validate!)
  end

  it "raises without exposing secret values when validation fails" do
    error = ProductionEnvValidator::ValidationError.new("Missing required production environment configuration: RAILS_MASTER_KEY")
    allow(ProductionEnvValidator).to receive(:validate!).with(strict: true).and_raise(error)
    allow(ProductionDataPlaneValidator).to receive(:validate!)

    expect { task.invoke }.to raise_error(ProductionEnvValidator::ValidationError)
      .and output(/RAILS_MASTER_KEY/).to_stderr
  end

  it "raises when data-plane validation fails" do
    error = ProductionDataPlaneValidator::ValidationError.new(
      "Missing required production data-plane configuration: database.production.queue"
    )
    allow(ProductionEnvValidator).to receive(:validate!).with(strict: true).and_return(
      ProductionEnvValidator::Result.new(missing_keys: [])
    )
    allow(ProductionDataPlaneValidator).to receive(:validate!).and_raise(error)

    expect { task.invoke }.to raise_error(ProductionDataPlaneValidator::ValidationError)
      .and output(/database\.production\.queue/).to_stderr
  end

  describe "recify:production:validate_data_plane" do
    let(:data_plane_task) { Rake::Task["recify:production:validate_data_plane"] }

    before do
      data_plane_task.reenable
    end

    it "calls the production data-plane validator" do
      allow(ProductionDataPlaneValidator).to receive(:validate!).and_return(
        ProductionDataPlaneValidator::Result.new(missing_items: [])
      )

      expect { data_plane_task.invoke }.to output(/Production data-plane configuration is valid/).to_stdout

      expect(ProductionDataPlaneValidator).to have_received(:validate!)
    end
  end
end
