# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260812211127_add_measurement_pricing_source_to_receipt_items")
require Rails.root.join("db/migrate/20260812211813_validate_measurement_pricing_source_constraints")

RSpec.describe AddMeasurementPricingSourceToReceiptItems do
  TEST_TABLE = :q2_measurement_pricing_items
  NEW_COLUMNS = %w[
    pricing_source_kind
    reference_price_amount
    reference_quantity
    reference_quantity_unit_code
    quantity_unit_raw
    reference_quantity_unit_raw
  ].freeze
  ROLLBACK_SOURCE_VALUES = {
    pricing_source_kind: "explicit_line_total",
    reference_price_amount: "120",
    reference_quantity: "500",
    reference_quantity_unit_code: "milliliter",
    quantity_unit_raw: "bottle",
    reference_quantity_unit_raw: "fl oz"
  }.freeze

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) do
    described_class.new.tap do |instance|
      allow(instance).to receive(:target_table_name).and_return(TEST_TABLE)
    end
  end
  let(:validation_migration) do
    ValidateMeasurementPricingSourceConstraints.new.tap do |instance|
      allow(instance).to receive(:target_table_name).and_return(TEST_TABLE)
    end
  end

  before do
    connection.create_table(TEST_TABLE) do |table|
      table.bigint :price
      table.decimal :quantity, precision: 10, scale: 3
      table.string :quantity_unit_code, null: false, default: "each"
      table.bigint :line_total
      table.bigint :original_line_total
      table.timestamps
    end
  end

  after do
    connection.drop_table(TEST_TABLE, if_exists: true)
  end

  describe "up" do
    it "adds only nullable source columns without defaults or numeric typemod rounding" do
      migrate_up

      columns = connection.columns(TEST_TABLE).index_by(&:name)

      expect(columns.values_at(*NEW_COLUMNS)).to all(have_attributes(null: true, default: nil))
      expect(columns.fetch("pricing_source_kind")).to have_attributes(type: :string, limit: nil)
      expect(columns.fetch("reference_price_amount")).to have_attributes(type: :decimal, precision: nil, scale: nil)
      expect(columns.fetch("reference_quantity")).to have_attributes(type: :decimal, precision: nil, scale: nil)
      expect(columns.fetch("reference_quantity_unit_code")).to have_attributes(type: :string, limit: nil)
      expect(columns.fetch("quantity_unit_raw")).to have_attributes(type: :string, limit: 64)
      expect(columns.fetch("reference_quantity_unit_raw")).to have_attributes(type: :string, limit: 64)
    end

    it "does not update or backfill a legacy row" do
      insert_row(
        price: 140,
        quantity: "8.120",
        quantity_unit_code: "liter",
        line_total: 1_137,
        original_line_total: 1_137
      )
      legacy_columns = "id, xmin::text AS xmin, price, quantity, quantity_unit_code, line_total, original_line_total"
      before_migration = select_row(legacy_columns)

      migrate_up

      after_migration = select_row("#{legacy_columns}, #{NEW_COLUMNS.join(', ')}")
      expect(after_migration.slice(*before_migration.keys))
        .to eq(before_migration)
      expect(after_migration.values_at(*NEW_COLUMNS)).to all(be_nil)
    end

    it "adds every check constraint as NOT VALID so the strong add-column lock is not held during scans" do
      migrate_up

      constraints = connection.check_constraints(TEST_TABLE)

      expect(constraints.map(&:name)).to contain_exactly(*described_class::CHECK_CONSTRAINT_NAMES)
      expect(constraints).to all(satisfy { |constraint| !constraint.validate? })
    end

    it "validates every check constraint in the follow-up migration" do
      migrate_up

      migrate_validation_up

      constraints = connection.check_constraints(TEST_TABLE)
      expect(constraints.map(&:name)).to contain_exactly(*described_class::CHECK_CONSTRAINT_NAMES)
      expect(constraints).to all(be_validate)
    end

    it "accepts the three complete evidence shapes and legacy absence" do
      migrate_up

      expect do
        insert_row
        insert_row(
          quantity: "8.120",
          quantity_unit_code: "liter",
          pricing_source_kind: "reference_quantity_price",
          reference_price_amount: "140.123456",
          reference_quantity: "1.000",
          reference_quantity_unit_code: "liter"
        )
        insert_row(
          price: 200,
          quantity: "2",
          quantity_unit_code: "box",
          pricing_source_kind: "count_unit_price"
        )
        insert_row(
          quantity: "1",
          quantity_unit_code: "kilogram",
          pricing_source_kind: "reference_quantity_price",
          reference_price_amount: "100",
          reference_quantity: "500",
          reference_quantity_unit_code: "gram"
        )
        insert_row(
          quantity: "1",
          quantity_unit_code: "liter",
          pricing_source_kind: "reference_quantity_price",
          reference_price_amount: "100",
          reference_quantity: "500",
          reference_quantity_unit_code: "milliliter"
        )
        insert_row(
          pricing_source_kind: nil,
          reference_price_amount: "120.000001",
          reference_quantity: "500.000",
          reference_quantity_unit_raw: "fl oz",
          quantity_unit_raw: "bottle"
        )
        insert_row(
          line_total: 360,
          pricing_source_kind: "explicit_line_total",
          reference_price_amount: "120",
          reference_quantity: "500",
          reference_quantity_unit_code: "milliliter",
          quantity_unit_raw: "container-mark"
        )
      end.not_to raise_error
    end

    it "accepts all fourteen canonical units for a complete reference tuple" do
      migrate_up

      expect do
        described_class::REFERENCE_UNIT_CODES.each do |unit_code|
          insert_row(
            quantity: "1",
            quantity_unit_code: unit_code,
            pricing_source_kind: "reference_quantity_price",
            reference_price_amount: "1",
            reference_quantity: "1",
            reference_quantity_unit_code: unit_code
          )
        end
      end.not_to raise_error
    end

    it "rejects unknown authority kinds and unknown canonical units" do
      migrate_up

      expect_statement_invalid(pricing_source_kind: "unsupported")
      expect_statement_invalid(
        quantity: "1",
        pricing_source_kind: "reference_quantity_price",
        reference_price_amount: "1",
        reference_quantity: "1",
        reference_quantity_unit_code: "ounce"
      )
    end

    it "rejects non-finite, out-of-range, and excess-scale reference prices without rounding them" do
      migrate_up

      %w[-Infinity Infinity NaN -0.000001 1000000000000 1.0000001].each do |value|
        expect_statement_invalid(
          pricing_source_kind: nil,
          reference_price_amount: value,
          reference_quantity: "1",
          reference_quantity_unit_code: "gram"
        )
      end

      expect do
        insert_row(
          pricing_source_kind: nil,
          reference_price_amount: "0",
          reference_quantity: "1",
          reference_quantity_unit_code: "gram"
        )
      end.not_to raise_error
      expect(select_value("reference_price_amount")).to eq(BigDecimal("0"))

      expect do
        insert_row(
          pricing_source_kind: nil,
          reference_price_amount: "999999999999",
          reference_quantity: "1",
          reference_quantity_unit_code: "gram"
        )
      end.not_to raise_error
      expect(select_value("reference_price_amount")).to eq(BigDecimal("999999999999"))

      expect do
        insert_row(
          pricing_source_kind: nil,
          reference_price_amount: "999999999998.999999",
          reference_quantity: "1",
          reference_quantity_unit_code: "gram"
        )
      end.not_to raise_error
      expect(select_value("reference_price_amount")).to eq(BigDecimal("999999999998.999999"))
    end

    it "rejects non-finite, non-positive, out-of-range, and excess-scale reference quantities without rounding them" do
      migrate_up

      %w[-Infinity Infinity NaN -0.001 0 10000 1.0001].each do |value|
        expect_statement_invalid(
          pricing_source_kind: nil,
          reference_price_amount: "1",
          reference_quantity: value,
          reference_quantity_unit_code: "gram"
        )
      end

      expect do
        insert_row(
          pricing_source_kind: nil,
          reference_price_amount: "1",
          reference_quantity: "9999.999",
          reference_quantity_unit_code: "gram"
        )
      end.not_to raise_error
      expect(select_value("reference_quantity")).to eq(BigDecimal("9999.999"))
    end

    it "rejects fractional reference quantities for countable units at the database boundary" do
      migrate_up

      described_class::COUNTABLE_UNIT_CODES.each do |unit_code|
        expect_statement_invalid(
          quantity: "2",
          quantity_unit_code: unit_code,
          pricing_source_kind: "reference_quantity_price",
          reference_price_amount: "100",
          reference_quantity: "1.5",
          reference_quantity_unit_code: unit_code
        )
      end

      expect do
        insert_row(
          quantity: "2",
          quantity_unit_code: "each",
          pricing_source_kind: "reference_quantity_price",
          reference_price_amount: "100",
          reference_quantity: "2",
          reference_quantity_unit_code: "each"
        )
      end.not_to raise_error
    end

    it "rejects blank, padded, control-character, and overlong raw evidence" do
      migrate_up

      [ "", "   ", " bottle", "bottle ", "bot\ttle", "bot\nle", "x" * 65 ].each do |value|
        expect_statement_invalid(quantity_unit_raw: value)
      end
      [ "", "   ", " fl oz", "fl oz ", "fl\toz", "fl\noz", "x" * 65 ].each do |value|
        expect_statement_invalid(
          reference_price_amount: "1",
          reference_quantity: "1",
          reference_quantity_unit_raw: value
        )
      end

      expect { insert_row(quantity_unit_raw: "bottle") }.not_to raise_error
    end

    it "rejects partial or mixed canonical and raw reference evidence" do
      migrate_up

      [
        { reference_price_amount: "1" },
        { reference_price_amount: "1", reference_quantity: "1" },
        { reference_price_amount: "1", reference_quantity_unit_code: "gram" },
        { reference_quantity: "1", reference_quantity_unit_raw: "oz" },
        {
          reference_price_amount: "1",
          reference_quantity: "1",
          reference_quantity_unit_code: "gram",
          reference_quantity_unit_raw: "g"
        }
      ].each { |attributes| expect_statement_invalid(**attributes) }
    end

    it "enforces the minimum source state for each authority kind" do
      migrate_up

      expect_statement_invalid(pricing_source_kind: "count_unit_price", reference_price_amount: "1",
        reference_quantity: "1", reference_quantity_unit_code: "each")
      expect_statement_invalid(pricing_source_kind: "count_unit_price", quantity_unit_raw: "個")
      expect_statement_invalid(pricing_source_kind: "count_unit_price", price: nil, quantity: "1")
      expect_statement_invalid(pricing_source_kind: "count_unit_price", price: 1, quantity: nil)
      expect_statement_invalid(
        pricing_source_kind: "count_unit_price",
        price: 1,
        quantity: "1",
        quantity_unit_code: "gram"
      )
      expect_statement_invalid(pricing_source_kind: "explicit_line_total")
      expect_statement_invalid(
        quantity: nil,
        pricing_source_kind: "reference_quantity_price",
        reference_price_amount: "1",
        reference_quantity: "1",
        reference_quantity_unit_code: "liter"
      )
      expect_statement_invalid(
        quantity: "1",
        quantity_unit_code: "gram",
        pricing_source_kind: "reference_quantity_price",
        reference_price_amount: "1",
        reference_quantity: "1",
        reference_quantity_unit_code: "liter"
      )
      expect_statement_invalid(
        quantity: "1",
        quantity_unit_code: "box",
        pricing_source_kind: "reference_quantity_price",
        reference_price_amount: "1",
        reference_quantity: "1",
        reference_quantity_unit_code: "each"
      )
      expect_statement_invalid(
        quantity: "1",
        quantity_unit_code: "liter",
        pricing_source_kind: "reference_quantity_price",
        reference_price_amount: "1",
        reference_quantity: "1",
        reference_quantity_unit_code: "liter",
        quantity_unit_raw: "L"
      )
      expect_statement_invalid(
        quantity: "1",
        pricing_source_kind: "reference_quantity_price",
        reference_price_amount: "1",
        reference_quantity: "1",
        reference_quantity_unit_raw: "L"
      )
    end

    it "enforces purchased quantity bounds and countable granularity for formula authorities" do
      migrate_up

      [ "0", "-1", "10000", "1.5" ].each do |quantity|
        expect_statement_invalid(
          price: 100,
          quantity: quantity,
          quantity_unit_code: "each",
          pricing_source_kind: "count_unit_price"
        )
        expect_statement_invalid(
          quantity: quantity,
          quantity_unit_code: "each",
          pricing_source_kind: "reference_quantity_price",
          reference_price_amount: "100",
          reference_quantity: "1",
          reference_quantity_unit_code: "each"
        )
      end

      expect do
        insert_row(
          price: 100,
          quantity: "9999",
          quantity_unit_code: "each",
          pricing_source_kind: "count_unit_price"
        )
        insert_row(
          quantity: "9999.999",
          quantity_unit_code: "liter",
          pricing_source_kind: "reference_quantity_price",
          reference_price_amount: "120",
          reference_quantity: "500",
          reference_quantity_unit_code: "milliliter"
        )
      end.not_to raise_error
    end
  end

  describe "down" do
    it "locks the table before checking for source data and removing columns" do
      migrate_up

      expect(migration).to receive(:lock_source_table!).ordered.and_call_original
      expect(migration).to receive(:refuse_source_data_loss!).ordered.and_call_original

      migrate_down
    end

    it "removes all six columns when every new value is null" do
      insert_row(
        price: 140,
        quantity: "8.120",
        quantity_unit_code: "liter",
        line_total: 1_137,
        original_line_total: 1_137
      )
      migrate_up

      migrate_validation_up
      expect { migrate_validation_down }.not_to raise_error
      expect { migrate_down }.not_to raise_error
      expect(connection.columns(TEST_TABLE).map(&:name)).not_to include(*NEW_COLUMNS)
      expect(select_row("price, quantity, quantity_unit_code, line_total, original_line_total")).to eq(
        "price" => 140,
        "quantity" => BigDecimal("8.120"),
        "quantity_unit_code" => "liter",
        "line_total" => 1_137,
        "original_line_total" => 1_137
      )
    end

    ROLLBACK_SOURCE_VALUES.each do |column_name, value|
      it "refuses both rollback steps without changing schema or data when #{column_name} is present" do
        migrate_up
        remove_test_check_constraints
        insert_row(column_name => value)
        constraint_names = connection.check_constraints(TEST_TABLE).map(&:name)
        source_values = select_row(NEW_COLUMNS.join(", "))

        expect { migrate_validation_down }
          .to raise_error(ActiveRecord::IrreversibleMigration, /measurement pricing validation/)
        expect { migrate_down }
          .to raise_error(ActiveRecord::IrreversibleMigration, /measurement pricing source data/)
        expect(connection.columns(TEST_TABLE).map(&:name)).to include(*NEW_COLUMNS)
        expect(connection.check_constraints(TEST_TABLE).map(&:name)).to match_array(constraint_names)
        expect(select_row(NEW_COLUMNS.join(", "))).to eq(source_values)
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
      price: nil,
      quantity: nil,
      quantity_unit_code: "each",
      line_total: nil,
      original_line_total: nil,
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
    connection.select_value("SELECT #{connection.quote_column_name(column)} FROM #{quoted_table} ORDER BY id DESC LIMIT 1")
  end

  def quoted_table
    connection.quote_table_name(TEST_TABLE)
  end

  def remove_test_check_constraints
    described_class::CHECK_CONSTRAINT_NAMES.each do |constraint_name|
      connection.remove_check_constraint(TEST_TABLE, name: constraint_name)
    end
  end
end
