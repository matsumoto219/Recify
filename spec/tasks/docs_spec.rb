require "rails_helper"
require "rake"

RSpec.describe "docs:verify_review_reasons" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("docs:verify_review_reasons")
  end

  let(:task) { Rake::Task["docs:verify_review_reasons"] }
  let(:codes) { ReviewReasons::ALL_REASONS.reverse }
  let(:document) { "# Review reasons\n\n#{codes.map { |code| "- #{code}" }.join("\n")}\n" }
  let(:doc_path) { instance_double(Pathname, file?: true, read: document) }

  before do
    task.reenable
    allow(Rails.root).to receive(:join).and_call_original
    allow(Rails.root).to receive(:join).with("docs/specs/review_reasons.md").and_return(doc_path)
  end

  it "verifies matching codes regardless of order" do
    expect { task.invoke }.to output("Review reason documentation verified.\n").to_stdout
  end

  it "fails when the local document is missing without reading it" do
    allow(doc_path).to receive(:file?).and_return(false)
    expect(doc_path).not_to receive(:read)

    expect { task.invoke }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      .and output("Missing local document: docs/specs/review_reasons.md\n").to_stderr
  end

  context "with a missing code" do
    let(:codes) { super().drop(1) }

    it "fails validation" do
      expect { task.invoke }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
        .and output("Review reason documentation does not match the formal reason list.\n").to_stderr
    end
  end

  context "with an unknown code" do
    let(:codes) { super() + [ "unknown_reason" ] }

    it "fails validation without printing the document" do
      expect { task.invoke }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
        .and output("Review reason documentation does not match the formal reason list.\n").to_stderr
    end
  end

  context "with a duplicate code" do
    let(:codes) { super() + [ ReviewReasons::ALL_REASONS.first ] }

    it "fails validation" do
      expect { task.invoke }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
        .and output("Review reason documentation does not match the formal reason list.\n").to_stderr
    end
  end

  context "with an empty document" do
    let(:document) { "" }

    it "fails validation" do
      expect { task.invoke }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
        .and output("Review reason documentation does not match the formal reason list.\n").to_stderr
    end
  end
end
