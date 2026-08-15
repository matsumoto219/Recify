# frozen_string_literal: true

class ValidateMeasurementPricingSourceConstraints < ActiveRecord::Migration[8.1]
  SOURCE_COLUMNS = %i[
    pricing_source_kind
    reference_price_amount
    reference_quantity
    reference_quantity_unit_code
    quantity_unit_raw
    reference_quantity_unit_raw
  ].freeze

  CHECK_CONSTRAINT_NAMES = %w[
    check_receipt_items_pricing_source_kind
    check_receipt_items_reference_price_amount
    check_receipt_items_reference_quantity
    check_receipt_items_reference_quantity_granularity
    check_receipt_items_reference_unit_code
    check_receipt_items_quantity_unit_raw
    check_receipt_items_reference_quantity_unit_raw
    check_receipt_items_reference_evidence
    check_receipt_items_pricing_source_state
  ].freeze

  def up
    validations = CHECK_CONSTRAINT_NAMES.map do |constraint_name|
      "VALIDATE CONSTRAINT #{quote_column_name(constraint_name)}"
    end.join(", ")

    execute "ALTER TABLE #{quote_table_name(target_table_name)} #{validations}"
  end

  def down
    lock_source_table!
    refuse_source_data_loss!

    # Validation changes no data or accepted values; the additive migration owns constraint removal.
  end

  private

  def target_table_name
    :receipt_items
  end

  def lock_source_table!
    execute "LOCK TABLE #{quote_table_name(target_table_name)} IN ACCESS EXCLUSIVE MODE"
  end

  def refuse_source_data_loss!
    present_predicate = SOURCE_COLUMNS.map do |column_name|
      "#{quote_column_name(column_name)} IS NOT NULL"
    end.join(" OR ")
    source_data_exists = select_value(<<~SQL.squish).to_i == 1
      SELECT CASE WHEN EXISTS (
        SELECT 1
        FROM #{quote_table_name(target_table_name)}
        WHERE #{present_predicate}
        LIMIT 1
      ) THEN 1 ELSE 0 END
    SQL
    return unless source_data_exists

    raise ActiveRecord::IrreversibleMigration,
      "cannot roll back measurement pricing validation while source data exists; retain both migrations"
  end
end
