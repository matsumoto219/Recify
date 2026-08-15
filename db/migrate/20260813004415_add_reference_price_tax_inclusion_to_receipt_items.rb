# frozen_string_literal: true

class AddReferencePriceTaxInclusionToReceiptItems < ActiveRecord::Migration[8.1]
  SOURCE_COLUMN = :reference_price_tax_inclusion

  CHECK_CONSTRAINTS = {
    "check_receipt_items_reference_price_tax_inclusion" => <<~SQL.squish,
      reference_price_tax_inclusion IS NULL
      OR reference_price_tax_inclusion IN ('gross', 'net')
    SQL
    "check_receipt_items_reference_price_tax_inclusion_state" => <<~SQL.squish
      CASE
        WHEN pricing_source_kind = 'reference_quantity_price'
          THEN reference_price_tax_inclusion IS NOT NULL
        WHEN pricing_source_kind = 'count_unit_price'
          THEN reference_price_tax_inclusion IS NULL
        WHEN pricing_source_kind IS NULL OR pricing_source_kind = 'explicit_line_total'
          THEN (
            reference_price_tax_inclusion IS NULL
            OR (
              reference_price_amount IS NOT NULL
              AND reference_quantity IS NOT NULL
              AND (
                (
                  reference_quantity_unit_code IS NOT NULL
                  AND reference_quantity_unit_raw IS NULL
                )
                OR (
                  reference_quantity_unit_code IS NULL
                  AND reference_quantity_unit_raw IS NOT NULL
                )
              )
            )
          )
        ELSE FALSE
      END
    SQL
  }.freeze
  CHECK_CONSTRAINT_NAMES = CHECK_CONSTRAINTS.keys.freeze

  def up
    add_column target_table_name, SOURCE_COLUMN, :string
    add_unvalidated_check_constraints
  end

  def down
    lock_source_table!
    refuse_source_data_loss!

    CHECK_CONSTRAINT_NAMES.reverse_each do |constraint_name|
      next unless check_constraint_exists?(target_table_name, name: constraint_name)

      remove_check_constraint target_table_name, name: constraint_name
    end

    remove_column target_table_name, SOURCE_COLUMN
  end

  private

  def target_table_name
    :receipt_items
  end

  def add_unvalidated_check_constraints
    definitions = CHECK_CONSTRAINTS.map do |constraint_name, expression|
      "ADD CONSTRAINT #{quote_column_name(constraint_name)} CHECK (#{expression}) NOT VALID"
    end.join(", ")

    execute "ALTER TABLE #{quote_table_name(target_table_name)} #{definitions}"
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
      "cannot remove reference price tax inclusion data; use application rollback and retain the additive column"
  end
end
