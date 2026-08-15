# frozen_string_literal: true

class ValidateReferencePriceTaxInclusionConstraints < ActiveRecord::Migration[8.1]
  SOURCE_COLUMN = :reference_price_tax_inclusion
  CHECK_CONSTRAINT_NAMES = %w[
    check_receipt_items_reference_price_tax_inclusion
    check_receipt_items_reference_price_tax_inclusion_state
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
    source_data_exists = select_value(<<~SQL.squish).to_i == 1
      SELECT CASE WHEN EXISTS (
        SELECT 1
        FROM #{quote_table_name(target_table_name)}
        WHERE #{quote_column_name(SOURCE_COLUMN)} IS NOT NULL
        LIMIT 1
      ) THEN 1 ELSE 0 END
    SQL
    return unless source_data_exists

    raise ActiveRecord::IrreversibleMigration,
      "cannot roll back reference price tax inclusion validation while source data exists; retain both migrations"
  end
end
