# frozen_string_literal: true

class ValidateReceiptCalculationSettings < ActiveRecord::Migration[8.1]
  CHECK_CONSTRAINT_NAMES = {
    users: %w[check_users_default_item_tax_inclusion],
    receipts: %w[check_receipts_calculation_settings],
    receipt_items: %w[
      check_receipt_items_input_tax_inclusion
      check_receipt_items_tax_inclusion_origin
      check_receipt_items_input_tax_inclusion_state
      check_receipt_items_gross_line_total
    ]
  }.freeze
  SOURCE_PREDICATES = {
    users: "default_item_tax_inclusion <> 'gross'",
    receipts: "calculation_settings IS NOT NULL",
    receipt_items: "input_tax_inclusion IS NOT NULL OR tax_inclusion_origin IS NOT NULL OR gross_line_total IS NOT NULL"
  }.freeze

  def up
    CHECK_CONSTRAINT_NAMES.each do |table, names|
      validations = names.map do |name|
        "VALIDATE CONSTRAINT #{quote_column_name(name)}"
      end.join(", ")

      execute "ALTER TABLE #{quote_table_name(target_table_name(table))} #{validations}"
    end
  end

  def down
    tables = SOURCE_PREDICATES.keys.map { |table| quote_table_name(target_table_name(table)) }.join(", ")
    execute "LOCK TABLE #{tables} IN ACCESS EXCLUSIVE MODE"
    SOURCE_PREDICATES.each do |table, predicate|
      source_data_exists = select_value(<<~SQL.squish).to_i == 1
        SELECT CASE WHEN EXISTS (
          SELECT 1
          FROM #{quote_table_name(target_table_name(table))}
          WHERE #{predicate}
          LIMIT 1
        ) THEN 1 ELSE 0 END
      SQL
      next unless source_data_exists

      raise ActiveRecord::IrreversibleMigration,
        "cannot roll back calculation settings validation while recorded data exists; retain both migrations"
    end

    # Validation changes no data or accepted values; the additive migration owns constraint removal.
  end

  private

  def target_table_name(table)
    table
  end
end
