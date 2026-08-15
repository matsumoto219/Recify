# frozen_string_literal: true

class AddMeasurementPricingSourceToReceiptItems < ActiveRecord::Migration[8.1]
  AUTHORITY_KINDS = %w[
    count_unit_price
    explicit_line_total
    reference_quantity_price
  ].freeze

  REFERENCE_UNIT_CODES = %w[
    each
    item
    piece
    bag
    sheet
    unit
    box
    set
    gram
    kilogram
    milligram
    liter
    milliliter
    cubic_centimeter
  ].freeze
  COUNTABLE_UNIT_CODES = %w[each item piece bag sheet unit box set].freeze
  MASS_UNIT_CODES = %w[gram kilogram milligram].freeze
  VOLUME_UNIT_CODES = %w[liter milliliter cubic_centimeter].freeze

  SOURCE_COLUMNS = %i[
    pricing_source_kind
    reference_price_amount
    reference_quantity
    reference_quantity_unit_code
    quantity_unit_raw
    reference_quantity_unit_raw
  ].freeze

  CHECK_CONSTRAINTS = {
    "check_receipt_items_pricing_source_kind" => <<~SQL.squish,
      pricing_source_kind IS NULL
      OR pricing_source_kind IN ('count_unit_price', 'explicit_line_total', 'reference_quantity_price')
    SQL
    "check_receipt_items_reference_price_amount" => <<~SQL.squish,
      reference_price_amount IS NULL
      OR (
        reference_price_amount >= 0
        AND reference_price_amount <= 999999999999
        AND reference_price_amount = round(reference_price_amount, 6)
      )
    SQL
    "check_receipt_items_reference_quantity" => <<~SQL.squish,
      reference_quantity IS NULL
      OR (
        reference_quantity > 0
        AND reference_quantity <= 9999.999
        AND reference_quantity = round(reference_quantity, 3)
      )
    SQL
    "check_receipt_items_reference_quantity_granularity" => <<~SQL.squish,
      reference_quantity IS NULL
      OR reference_quantity_unit_code IS NULL
      OR reference_quantity_unit_code NOT IN ('each', 'item', 'piece', 'bag', 'sheet', 'unit', 'box', 'set')
      OR reference_quantity = trunc(reference_quantity)
    SQL
    "check_receipt_items_reference_unit_code" => <<~SQL.squish,
      reference_quantity_unit_code IS NULL
      OR reference_quantity_unit_code IN (
        'each', 'item', 'piece', 'bag', 'sheet', 'unit', 'box', 'set',
        'gram', 'kilogram', 'milligram', 'liter', 'milliliter', 'cubic_centimeter'
      )
    SQL
    "check_receipt_items_quantity_unit_raw" => <<~SQL.squish,
      quantity_unit_raw IS NULL
      OR (
        char_length(quantity_unit_raw) BETWEEN 1 AND 64
        AND quantity_unit_raw = btrim(quantity_unit_raw)
        AND quantity_unit_raw <> ''
        AND quantity_unit_raw !~ '[[:cntrl:]]'
      )
    SQL
    "check_receipt_items_reference_quantity_unit_raw" => <<~SQL.squish,
      reference_quantity_unit_raw IS NULL
      OR (
        char_length(reference_quantity_unit_raw) BETWEEN 1 AND 64
        AND reference_quantity_unit_raw = btrim(reference_quantity_unit_raw)
        AND reference_quantity_unit_raw <> ''
        AND reference_quantity_unit_raw !~ '[[:cntrl:]]'
      )
    SQL
    "check_receipt_items_reference_evidence" => <<~SQL.squish,
      (
        reference_price_amount IS NULL
        AND reference_quantity IS NULL
        AND reference_quantity_unit_code IS NULL
        AND reference_quantity_unit_raw IS NULL
      )
      OR (
        reference_price_amount IS NOT NULL
        AND reference_quantity IS NOT NULL
        AND reference_quantity_unit_code IS NOT NULL
        AND reference_quantity_unit_raw IS NULL
      )
      OR (
        reference_price_amount IS NOT NULL
        AND reference_quantity IS NOT NULL
        AND reference_quantity_unit_code IS NULL
        AND reference_quantity_unit_raw IS NOT NULL
      )
    SQL
    "check_receipt_items_pricing_source_state" => <<~SQL.squish
      pricing_source_kind IS NULL
      OR (
        pricing_source_kind = 'count_unit_price'
        AND price IS NOT NULL
        AND quantity IS NOT NULL
        AND quantity > 0
        AND quantity <= 9999.999
        AND quantity = trunc(quantity)
        AND quantity_unit_code IN ('each', 'item', 'piece', 'bag', 'sheet', 'unit', 'box', 'set')
        AND reference_price_amount IS NULL
        AND reference_quantity IS NULL
        AND reference_quantity_unit_code IS NULL
        AND quantity_unit_raw IS NULL
        AND reference_quantity_unit_raw IS NULL
      )
      OR (
        pricing_source_kind = 'explicit_line_total'
        AND line_total IS NOT NULL
      )
      OR (
        pricing_source_kind = 'reference_quantity_price'
        AND quantity IS NOT NULL
        AND quantity > 0
        AND quantity <= 9999.999
        AND (
          quantity_unit_code NOT IN ('each', 'item', 'piece', 'bag', 'sheet', 'unit', 'box', 'set')
          OR quantity = trunc(quantity)
        )
        AND (
          quantity_unit_code = reference_quantity_unit_code
          OR (
            quantity_unit_code IN ('gram', 'kilogram', 'milligram')
            AND reference_quantity_unit_code IN ('gram', 'kilogram', 'milligram')
          )
          OR (
            quantity_unit_code IN ('liter', 'milliliter', 'cubic_centimeter')
            AND reference_quantity_unit_code IN ('liter', 'milliliter', 'cubic_centimeter')
          )
        )
        AND reference_price_amount IS NOT NULL
        AND reference_quantity IS NOT NULL
        AND reference_quantity_unit_code IS NOT NULL
        AND quantity_unit_raw IS NULL
        AND reference_quantity_unit_raw IS NULL
      )
    SQL
  }.freeze
  CHECK_CONSTRAINT_NAMES = CHECK_CONSTRAINTS.keys.freeze

  def up
    change_table target_table_name, bulk: true do |table|
      table.string :pricing_source_kind
      table.decimal :reference_price_amount
      table.decimal :reference_quantity
      table.string :reference_quantity_unit_code
      table.string :quantity_unit_raw, limit: 64
      table.string :reference_quantity_unit_raw, limit: 64
    end

    add_unvalidated_check_constraints
  end

  def down
    lock_source_table!
    refuse_source_data_loss!

    CHECK_CONSTRAINT_NAMES.reverse_each do |constraint_name|
      next unless check_constraint_exists?(target_table_name, name: constraint_name)

      remove_check_constraint target_table_name, name: constraint_name
    end

    change_table target_table_name, bulk: true do |table|
      SOURCE_COLUMNS.each { |column_name| table.remove column_name }
    end
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
      "cannot remove measurement pricing source data; use application rollback and retain the additive columns"
  end
end
