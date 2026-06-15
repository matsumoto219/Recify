# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "recify:env tasks" do
  before(:all) do
    Rails.application.load_tasks
  end

  let(:task) { Rake::Task["recify:env:validate"] }

  before do
    task.reenable
  end

  it "calls the production environment validator in strict mode" do
    allow(ProductionEnvValidator).to receive(:validate!).with(strict: true).and_return(
      ProductionEnvValidator::Result.new(missing_keys: [])
    )

    expect { task.invoke }.to output(/Production environment configuration is valid/).to_stdout

    expect(ProductionEnvValidator).to have_received(:validate!).with(strict: true)
  end

  it "raises without exposing secret values when validation fails" do
    error = ProductionEnvValidator::ValidationError.new("Missing required production environment configuration: RAILS_MASTER_KEY")
    allow(ProductionEnvValidator).to receive(:validate!).with(strict: true).and_raise(error)

    expect { task.invoke }.to raise_error(ProductionEnvValidator::ValidationError)
      .and output(/RAILS_MASTER_KEY/).to_stderr
  end
end
