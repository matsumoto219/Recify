namespace :docs do
  desc "Verify the local review reason document against the formal reason list"
  task verify_review_reasons: :environment do
    doc_path = Rails.root.join("docs/specs/review_reasons.md")
    abort "Missing local document: docs/specs/review_reasons.md" unless doc_path.file?

    doc_codes = doc_path.read.scan(/^- ([a-z0-9_]+)$/).flatten
    unless doc_codes.sort == ReviewReasons::ALL_REASONS.sort
      abort "Review reason documentation does not match the formal reason list."
    end

    puts "Review reason documentation verified."
  end
end
