# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260917141034_add_receipt_calculation_settings")
require Rails.root.join("db/migrate/20260917141145_validate_receipt_calculation_settings")

RSpec.describe AddReceiptCalculationSettings do
  TABLES = {
    users: :calculation_settings_test_users,
    receipts: :calculation_settings_test_receipts,
    receipt_items: :calculation_settings_test_items
  }.freeze
  SETTINGS = {
    "schema_version" => 1,
    "tax_rounding_mode" => { "value" => "floor", "origin" => "form_default" }
  }.freeze

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) do
    described_class.new.tap do |instance|
      allow(instance).to receive(:target_table_name) { |table| TABLES.fetch(table) }
    end
  end
  let(:validation_migration) do
    ValidateReceiptCalculationSettings.new.tap do |instance|
      allow(instance).to receive(:target_table_name) { |table| TABLES.fetch(table) }
    end
  end

  before do
    connection.create_table(TABLES.fetch(:users)) { |table| table.string :name }
    connection.create_table(TABLES.fetch(:receipts)) { |table| table.bigint :total_amount }
    connection.create_table(TABLES.fetch(:receipt_items)) do |table|
      table.string :pricing_source_kind
      table.string :reference_price_tax_inclusion
      table.bigint :line_total
    end
  end

  after do
    TABLES.values.reverse_each { |table| connection.drop_table(table, if_exists: true) }
  end

  describe "up" do
    it "adds only one defaulted User preference and nullable receipt source/projection columns" do
      migrate(:up)

      expect(column(:users, "default_item_tax_inclusion"))
        .to have_attributes(type: :string, limit: 5, null: false, default: "gross")
      expect(column(:receipts, "calculation_settings"))
        .to have_attributes(type: :jsonb, null: true, default: nil)
      expect(column(:receipt_items, "input_tax_inclusion"))
        .to have_attributes(type: :string, limit: 5, null: true, default: nil)
      expect(column(:receipt_items, "tax_inclusion_origin"))
        .to have_attributes(type: :string, limit: 24, null: true, default: nil)
      expect(column(:receipt_items, "gross_line_total"))
        .to have_attributes(type: :integer, limit: 8, null: true, default: nil)
    end

    it "does not rewrite existing receipt amounts or row versions" do
      insert(:receipts, total_amount: 731)
      insert(:receipt_items, pricing_source_kind: nil, line_total: 731)
      receipt_before = row(:receipts, "id, xmin::text AS xmin, total_amount")
      item_before = row(:receipt_items, "id, xmin::text AS xmin, line_total")

      migrate(:up)

      expect(row(:receipts, "id, xmin::text AS xmin, total_amount, calculation_settings"))
        .to eq(receipt_before.merge("calculation_settings" => nil))
      expect(row(:receipt_items, "id, xmin::text AS xmin, line_total, input_tax_inclusion, tax_inclusion_origin, gross_line_total"))
        .to eq(item_before.merge("input_tax_inclusion" => nil, "tax_inclusion_origin" => nil, "gross_line_total" => nil))
    end

    it "uses unvalidated checks that already protect new writes" do
      migrate(:up)

      TABLES.each_value do |table|
        expect(connection.check_constraints(table)).not_to be_empty
        expect(connection.check_constraints(table)).to all(satisfy { |constraint| !constraint.validate? })
      end
      expect_invalid(:users, default_item_tax_inclusion: "other")
      expect_invalid(:users, default_item_tax_inclusion: nil)
    end

    it "validates all checks in a separate migration" do
      migrate(:up)
      validation_migration.suppress_messages { validation_migration.migrate(:up) }

      TABLES.each_value do |table|
        expect(connection.check_constraints(table)).to all(be_validate)
      end
    end

    it "accepts partial known receipt settings and rejects unknown or malformed JSON" do
      migrate(:up)

      expect { insert(:receipts, calculation_settings: SETTINGS.to_json) }.not_to raise_error
      invalid_settings = [
        {}, { "schema_version" => 1 }, [], "private", 1, false,
        SETTINGS.merge("schema_version" => 2), SETTINGS.merge("schema_version" => "1"),
        SETTINGS.merge("schema_version" => 1.5), SETTINGS.merge("private" => "value"),
        SETTINGS.merge("tax_rounding_mode" => nil),
        SETTINGS.merge("tax_rounding_mode" => "floor"),
        SETTINGS.merge("tax_rounding_mode" => { "value" => "floor" }),
        SETTINGS.merge("tax_rounding_mode" => { "origin" => "manual" }),
        SETTINGS.merge("tax_rounding_mode" => { "value" => "floor", "origin" => "unknown" }),
        SETTINGS.merge("tax_rounding_mode" => { "value" => "unknown", "origin" => "manual" }),
        SETTINGS.merge("tax_rounding_mode" => { "value" => "floor", "origin" => "manual", "raw" => "text" }),
        SETTINGS.merge("tax_rounding_scope" => { "value" => "other", "origin" => "manual" }),
        SETTINGS.merge("purchase_adjustment_tax_inclusion" => { "value" => "net", "origin" => "x" * 5_000 })
      ]
      invalid_settings.each { |settings| expect_invalid(:receipts, calculation_settings: settings.to_json) }
      expect_invalid(:receipts, calculation_settings: "null")
    end

    it "keeps typed source tax inclusion independent of reference diagnostics" do
      migrate(:up)

      %w[gross net].each do |basis|
        %w[count_unit_price explicit_line_total].each do |kind|
          expect do
            insert(:receipt_items, pricing_source_kind: kind, input_tax_inclusion: basis, tax_inclusion_origin: "manual")
          end.not_to raise_error
        end
        expect do
          insert(
            :receipt_items,
            pricing_source_kind: "reference_quantity_price",
            reference_price_tax_inclusion: basis,
            tax_inclusion_origin: "analysis"
          )
        end.not_to raise_error
      end
      expect do
        insert(
          :receipt_items,
          pricing_source_kind: "explicit_line_total",
          input_tax_inclusion: "gross",
          tax_inclusion_origin: "manual",
          reference_price_tax_inclusion: "net"
        )
        insert(:receipt_items, pricing_source_kind: nil)
        insert(:receipt_items, pricing_source_kind: "reference_quantity_price", reference_price_tax_inclusion: "gross")
      end.not_to raise_error
    end

    it "rejects orphan basis/origin and basis assigned to the wrong authority" do
      migrate(:up)

      expect_invalid(:receipt_items, input_tax_inclusion: "gross", tax_inclusion_origin: "manual")
      expect_invalid(:receipt_items, pricing_source_kind: "count_unit_price", input_tax_inclusion: "gross")
      expect_invalid(:receipt_items, pricing_source_kind: "count_unit_price", tax_inclusion_origin: "manual")
      expect_invalid(:receipt_items, pricing_source_kind: "count_unit_price", input_tax_inclusion: "other", tax_inclusion_origin: "manual")
      expect_invalid(:receipt_items, pricing_source_kind: "explicit_line_total", input_tax_inclusion: "net", tax_inclusion_origin: "unknown")
      expect_invalid(
        :receipt_items,
        pricing_source_kind: "reference_quantity_price",
        reference_price_tax_inclusion: "gross",
        input_tax_inclusion: "gross",
        tax_inclusion_origin: "manual"
      )
      expect_invalid(:receipt_items, pricing_source_kind: "reference_quantity_price", tax_inclusion_origin: "manual")
    end

    it "bounds gross projection independently of its source amount" do
      migrate(:up)

      expect { insert(:receipt_items, gross_line_total: 0) }.not_to raise_error
      expect { insert(:receipt_items, gross_line_total: 999_999_999_999) }.not_to raise_error
      expect_invalid(:receipt_items, gross_line_total: -1)
      expect_invalid(:receipt_items, gross_line_total: 1_000_000_000_000)
    end
  end

  describe "down" do
    it "allows down only while all new financial fields are unused and preferences remain default" do
      insert(:receipts, total_amount: 731)
      migrate(:up)
      insert(:users, default_item_tax_inclusion: "gross")

      migrate(:down)

      expect(connection.column_exists?(TABLES.fetch(:receipts), :calculation_settings)).to be(false)
      expect(row(:receipts, "total_amount")).to eq("total_amount" => 731)
    end

    [
      [ :users, { default_item_tax_inclusion: "net" } ],
      [ :receipts, { calculation_settings: SETTINGS.to_json } ],
      [ :receipt_items, { gross_line_total: 0 } ],
      [ :receipt_items, { pricing_source_kind: "explicit_line_total", input_tax_inclusion: "gross", tax_inclusion_origin: "manual" } ]
    ].each do |table, attributes|
      it "protects recorded #{attributes.keys.first} on down" do
        migrate(:up)
        insert(table, **attributes)

        expect { migrate(:down) }.to raise_error(ActiveRecord::IrreversibleMigration, /calculation settings/)
        expect { validation_migration.suppress_messages { validation_migration.migrate(:down) } }
          .to raise_error(ActiveRecord::IrreversibleMigration, /calculation settings validation/)
        expect(connection.column_exists?(TABLES.fetch(:receipts), :calculation_settings)).to be(true)
      end
    end
  end

  def migrate(direction)
    migration.suppress_messages { migration.migrate(direction) }
  end

  def column(table, name)
    connection.columns(TABLES.fetch(table)).find { |entry| entry.name == name }
  end

  def insert(table, **attributes)
    columns = attributes.keys.map { |key| connection.quote_column_name(key) }.join(", ")
    values = attributes.values.map { |value| connection.quote(value) }.join(", ")
    connection.execute("INSERT INTO #{connection.quote_table_name(TABLES.fetch(table))} (#{columns}) VALUES (#{values})")
  end

  def row(table, columns)
    connection.select_one("SELECT #{columns} FROM #{connection.quote_table_name(TABLES.fetch(table))} ORDER BY id DESC LIMIT 1")
  end

  def expect_invalid(table, **attributes)
    expect do
      connection.transaction(requires_new: true) { insert(table, **attributes) }
    end.to raise_error(ActiveRecord::StatementInvalid)
  end
end
