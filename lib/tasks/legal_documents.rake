namespace :legal_documents do
  desc "Verify versioned legal document YAML files"
  task verify_files: :environment do
    LegalDocuments::Verifier.verify_files!
    puts "Legal document files verified."
  end

  desc "Synchronize versioned legal document YAML metadata into the database"
  task sync: :environment do
    result = LegalDocuments::Sync.call(dry_run: ActiveModel::Type::Boolean.new.cast(ENV["DRY_RUN"]))
    puts [
      "Legal documents sync complete.",
      "created=#{result.created.size}",
      "updated=#{result.updated.size}",
      "current=#{result.current.size}"
    ].join(" ")
  end

  desc "Verify legal document database rows against versioned YAML files"
  task verify: :environment do
    LegalDocuments::Verifier.verify_database!
    puts "Legal documents database verified."
  end
end
