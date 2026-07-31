# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Active Storage security dependency" do
  it "uses an Active Storage release containing the variant processing security fix" do
    active_storage_version = Gem.loaded_specs.fetch("activestorage").version

    expect(active_storage_version).to be >= Gem::Version.new("8.1.3.1")
  end

  it "keeps the Rails framework components on the same patched release" do
    framework_names = %w[
      actioncable actionmailbox actionmailer actionpack actiontext actionview
      activejob activemodel activerecord activestorage activesupport rails railties
    ]
    framework_versions = Bundler.load.specs
      .select { |spec| framework_names.include?(spec.name) }
      .map(&:version)
    rails_version = Gem.loaded_specs.fetch("rails").version

    expect(rails_version).to be >= Gem::Version.new("8.1.3.1")
    expect(framework_versions.uniq).to contain_exactly(rails_version)
  end

  it "uses the vips processor with runtimes that meet Active Storage's security requirements" do
    ruby_vips_version = Gem.loaded_specs.fetch("ruby-vips").version

    expect(Rails.application.config.active_storage.variant_processor).to eq(:vips)
    expect(ruby_vips_version).to be >= Gem::Version.new("2.2.1")
    expect(Vips).to respond_to(:block_untrusted)
    expect(Vips.at_least_libvips?(8, 13)).to be(true)
  end

  it "processes a normal image variant with the configured vips processor" do
    fixture_path = Rails.root.join(
      "spec/fixtures/generated_receipts/images/g001_normal_included_10_cash.png"
    )
    blob = fixture_path.open("rb") do |io|
      ActiveStorage::Blob.create_and_upload!(
        io: io,
        filename: fixture_path.basename,
        content_type: "image/png"
      )
    end

    variant = blob.variant(resize_to_limit: [ 64, 64 ]).processed
    processed_image = Vips::Image.new_from_buffer(variant.download, "")

    expect(processed_image.width).to be <= 64
    expect(processed_image.height).to be <= 64
  ensure
    blob&.purge
  end
end
