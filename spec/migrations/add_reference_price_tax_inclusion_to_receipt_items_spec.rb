# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260813004415_add_reference_price_tax_inclusion_to_receipt_items")
require Rails.root.join("db/migrate/20260813004416_validate_reference_price_tax_inclusion_constraints")

RSpec.describe AddReferencePriceTaxInclusionToReceiptItems do
  TAX_INCLUSION_TEST_TABLE = :q2_reference_price_tax_inclusion_items
  NEW_COLUMN = "reference_price_tax_inclusion"
  COMPLETE_CANONICAL_EVIDENCE = {
    reference_price_amount: "120",
    reference_quantity: "500",
    reference_quantity_unit_code: "milliliter",
    reference_quantity_unit_raw: nil
  }.freeze
  COMPLETE_RAW_EVIDENCE = {
    reference_price_amount: "120",
    reference_quantity: "16",
    reference_quantity_unit_code: nil,
    reference_quantity_unit_raw: "fluid_ounce"
  }.freeze

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) do
    described_class.new.tap do |instance|
      allow(instance).to receive(:target_table_name).and_return(TAX_INCLUSION_TEST_TABLE)
    end
  end
  let(:validation_migration) do
    ValidateReferencePriceTaxInclusionConstraints.new.tap do |instance|
      allow(instance).to receive(:target_table_name).and_return(TAX_INCLUSION_TEST_TABLE)
    end
  end

  before do
    connection.create_table(TAX_INCLUSION_TEST_TABLE) do |table|
      table.string :pricing_source_kind
      table.decimal :reference_price_amount
      table.decimal :reference_quantity
      table.string :reference_quantity_unit_code
      table.string :reference_quantity_unit_raw, limit: 64
      table.bigint :line_total
      table.timestamps
    end
  end

  after do
    connection.drop_table(TAX_INCLUSION_TEST_TABLE, if_exists: true)
  end

  describe "up" do
    it "adds one nullable source column without a default" do
      migrate_up

      column = connection.columns(TAX_INCLUSION_TEST_TABLE).index_by(&:name).fetch(NEW_COLUMN)

      expect(column).to have_attributes(type: :string, limit: nil, null: true, default: nil)
    end

    it "does not update or backfill legacy rows" do
      insert_row(
        pricing_source_kind: "explicit_line_total",
        line_total: 1_137
      )
      legacy_columns = "id, xmin::text AS xmin, pricing_source_kind, line_total"
      before_migration = select_row(legacy_columns)

      migrate_up

      after_migration = select_row("#{legacy_columns}, #{NEW_COLUMN}")
      expect(after_migration.slice(*before_migration.keys)).to eq(before_migration)
      expect(after_migration.fetch(NEW_COLUMN)).to be_nil
    end

    it "adds the check constraints as NOT VALID before the separate validation migration" do
      migrate_up

      constraints = connection.check_constraints(TAX_INCLUSION_TEST_TABLE)

      expect(constraints.map(&:name)).to contain_exactly(*described_class::CHECK_CONSTRAINT_NAMES)
      expect(constraints).to all(satisfy { |constraint| !constraint.validate? })
    end

    it "validates every check constraint in the follow-up migration" do
      migrate_up

      migrate_validation_up

      constraints = connection.check_constraints(TAX_INCLUSION_TEST_TABLE)
      expect(constraints.map(&:name)).to contain_exactly(*described_class::CHECK_CONSTRAINT_NAMES)
      expect(constraints).to all(be_validate)
    end

    it "accepts gross and net for reference authority and either complete diagnostic evidence" do
      migrate_up

      expect do
        %w[gross net].each do |tax_inclusion|
          insert_row(
            pricing_source_kind: "reference_quantity_price",
            reference_price_tax_inclusion: tax_inclusion,
            **COMPLETE_CANONICAL_EVIDENCE
          )
          [ nil, "explicit_line_total" ].each do |pricing_source_kind|
            [ COMPLETE_CANONICAL_EVIDENCE, COMPLETE_RAW_EVIDENCE ].each do |evidence|
              insert_row(
                pricing_source_kind: pricing_source_kind,
                line_total: pricing_source_kind.nil? ? nil : 240,
                reference_price_tax_inclusion: tax_inclusion,
                **evidence
              )
            end
          end
        end
      end.not_to raise_error
    end

    it "accepts null for legacy, count, and explicit rows without reference evidence" do
      migrate_up

      expect do
        insert_row(pricing_source_kind: nil)
        insert_row(pricing_source_kind: "count_unit_price")
        insert_row(pricing_source_kind: "explicit_line_total", line_total: 240)
      end.not_to raise_error
    end

    it "rejects unknown tax inclusion values" do
      migrate_up

      expect_statement_invalid(
        pricing_source_kind: "reference_quantity_price",
        reference_price_tax_inclusion: "unknown",
        **COMPLETE_CANONICAL_EVIDENCE
      )
    end

    it "requires tax inclusion for reference authority and forbids it for count authority" do
      migrate_up

      expect_statement_invalid(
        pricing_source_kind: "reference_quantity_price",
        reference_price_tax_inclusion: nil,
        **COMPLETE_CANONICAL_EVIDENCE
      )
      expect_statement_invalid(
        pricing_source_kind: "count_unit_price",
        reference_price_tax_inclusion: "gross",
        **COMPLETE_CANONICAL_EVIDENCE
      )
    end

    it "allows tax inclusion for nil or explicit authority only with complete reference evidence" do
      migrate_up

      [ nil, "explicit_line_total" ].each do |pricing_source_kind|
        common = {
          pricing_source_kind: pricing_source_kind,
          line_total: pricing_source_kind.nil? ? nil : 240,
          reference_price_tax_inclusion: "net"
        }

        expect_statement_invalid(**common)
        expect_statement_invalid(**common, reference_price_amount: "120")
        expect_statement_invalid(
          **common,
          reference_price_amount: "120",
          reference_quantity: "500",
          reference_quantity_unit_code: "milliliter",
          reference_quantity_unit_raw: "ml"
        )
      end
    end
  end

  describe "down" do
    it "locks the table before checking for source data and removing the column" do
      migrate_up

      expect(migration).to receive(:lock_source_table!).ordered.and_call_original
      expect(migration).to receive(:refuse_source_data_loss!).ordered.and_call_original

      migrate_down
    end

    it "locks the table before the validation rollback guard" do
      migrate_up
      migrate_validation_up

      expect(validation_migration).to receive(:lock_source_table!).ordered.and_call_original
      expect(validation_migration).to receive(:refuse_source_data_loss!).ordered.and_call_original

      migrate_validation_down
    end

    it "removes the column when every value is null and preserves legacy values" do
      insert_row(
        pricing_source_kind: "explicit_line_total",
        line_total: 1_137
      )
      migrate_up
      migrate_validation_up

      expect { migrate_validation_down }.not_to raise_error
      expect { migrate_down }.not_to raise_error
      expect(connection.columns(TAX_INCLUSION_TEST_TABLE).map(&:name)).not_to include(NEW_COLUMN)
      expect(select_row("pricing_source_kind, line_total")).to eq(
        "pricing_source_kind" => "explicit_line_total",
        "line_total" => 1_137
      )
    end

    %w[gross net].each do |tax_inclusion|
      it "refuses both rollback steps without changing schema or data when #{tax_inclusion} is present" do
        migrate_up
        insert_row(
          pricing_source_kind: "reference_quantity_price",
          reference_price_tax_inclusion: tax_inclusion,
          **COMPLETE_CANONICAL_EVIDENCE
        )
        migrate_validation_up
        constraint_names = connection.check_constraints(TAX_INCLUSION_TEST_TABLE).map(&:name)

        expect { migrate_validation_down }
          .to raise_error(ActiveRecord::IrreversibleMigration, /reference price tax inclusion validation/)
        expect { migrate_down }
          .to raise_error(ActiveRecord::IrreversibleMigration, /reference price tax inclusion data/)
        expect(connection.columns(TAX_INCLUSION_TEST_TABLE).map(&:name)).to include(NEW_COLUMN)
        expect(connection.check_constraints(TAX_INCLUSION_TEST_TABLE).map(&:name)).to match_array(constraint_names)
        expect(select_value(NEW_COLUMN)).to eq(tax_inclusion)
      end
    end
  end

  def migrate_up
    migration.suppress_messages { migration.migrate(:up) }
  end

  def migrate_down
    migration.suppress_messages { migration.migrate(:down) }
  end

  def migrate_validation_up
    validation_migration.suppress_messages { validation_migration.migrate(:up) }
  end

  def migrate_validation_down
    validation_migration.suppress_messages { validation_migration.migrate(:down) }
  end

  def insert_row(**attributes)
    defaults = {
      pricing_source_kind: nil,
      reference_price_amount: nil,
      reference_quantity: nil,
      reference_quantity_unit_code: nil,
      reference_quantity_unit_raw: nil,
      line_total: nil,
      created_at: Time.current,
      updated_at: Time.current
    }
    values = defaults.merge(attributes)
    columns = values.keys.map { |column| connection.quote_column_name(column) }.join(", ")
    literals = values.values.map { |value| connection.quote(value) }.join(", ")

    connection.execute("INSERT INTO #{quoted_table} (#{columns}) VALUES (#{literals})")
  end

  def expect_statement_invalid(**attributes)
    expect do
      connection.transaction(requires_new: true) { insert_row(**attributes) }
    end.to raise_error(ActiveRecord::StatementInvalid)
  end

  def select_row(columns)
    connection.select_one("SELECT #{columns} FROM #{quoted_table} ORDER BY id DESC LIMIT 1")
  end

  def select_value(column)
    connection.select_value(
      "SELECT #{connection.quote_column_name(column)} FROM #{quoted_table} ORDER BY id DESC LIMIT 1"
    )
  end

  def quoted_table
    connection.quote_table_name(TAX_INCLUSION_TEST_TABLE)
  end
end
