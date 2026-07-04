require 'rails_helper'

RSpec.describe 'Amount Engine service boundary' do
  TARGET_GLOBS = %w[
    app/controllers/**/*.rb
    app/jobs/**/*.rb
    app/models/**/*.rb
    app/helpers/**/*.rb
    app/presenters/**/*.rb
    app/services/**/*.rb
  ].freeze
  ALLOWED_SERVICE_PATHS = %w[
    app/services/receipt_amount_service.rb
  ].freeze
  ALLOWED_SERVICE_GLOBS = %w[
    app/services/amounts/**/*.rb
  ].freeze
  AMOUNTS_CHILD_REFERENCE = /\bAmounts::[A-Z][A-Za-z0-9_:]*/.freeze

  it 'app layers outside ReceiptAmountService do not call Amounts child implementations directly' do
    references = target_files.flat_map do |path|
      path.readlines.filter_map.with_index(1) do |line, line_number|
        next unless line.match?(AMOUNTS_CHILD_REFERENCE)

        "#{relative_path(path)}:#{line_number}: #{line.strip}"
      end
    end

    expect(references).to be_empty, references.join("\n")
  end

  def target_files
    TARGET_GLOBS.flat_map { |pattern| Rails.root.glob(pattern) }.uniq.sort.reject do |path|
      allowed_service_path?(path)
    end
  end

  def relative_path(path)
    path.relative_path_from(Rails.root)
  end

  def allowed_service_path?(path)
    relative = relative_path(path).to_s
    ALLOWED_SERVICE_PATHS.include?(relative) ||
      ALLOWED_SERVICE_GLOBS.any? { |pattern| File.fnmatch?(pattern, relative, File::FNM_PATHNAME) }
  end
end
