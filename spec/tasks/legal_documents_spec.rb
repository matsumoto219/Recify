require "rails_helper"
require "rake"

RSpec.describe "legal_documents tasks" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("legal_documents:verify_files")
  end

  before do
    LegalAcceptance.delete_all
    LegalDocument.delete_all
  end

  describe "legal_documents:verify_files" do
    let(:task) { Rake::Task["legal_documents:verify_files"] }

    before do
      task.reenable
    end

    it "verifies versioned YAML files" do
      expect { task.invoke }.to output(/Legal document files verified/).to_stdout
    end
  end

  describe "legal_documents:sync" do
    let(:task) { Rake::Task["legal_documents:sync"] }

    before do
      task.reenable
    end

    it "synchronizes legal documents" do
      expect do
        task.invoke
      end.to change(LegalDocument, :count).by(2)
        .and output(/Legal documents sync complete/).to_stdout
    end
  end

  describe "legal_documents:verify" do
    let(:task) { Rake::Task["legal_documents:verify"] }

    before do
      task.reenable
      LegalDocuments::Sync.call
    end

    it "verifies the database projection" do
      expect { task.invoke }.to output(/Legal documents database verified/).to_stdout
    end
  end
end
