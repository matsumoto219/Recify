# frozen_string_literal: true

class AddReceiptCalculationSettings < ActiveRecord::Migration[8.1]
  SETTING_VALUES = {
    "tax_rounding_mode" => %w[floor round ceil],
    "discount_rounding_mode" => %w[floor round ceil],
    "tax_rounding_scope" => %w[per_item per_tax_rate_group per_receipt],
    "purchase_adjustment_tax_inclusion" => %w[gross net]
  }.freeze
  ORIGINS = %w[manual form_default application_default analysis legacy_record].freeze
  SOURCE_PREDICATES = {
    users: "default_item_tax_inclusion <> 'gross'",
    receipts: "calculation_settings IS NOT NULL",
    receipt_items: "input_tax_inclusion IS NOT NULL OR tax_inclusion_origin IS NOT NULL OR gross_line_total IS NOT NULL"
  }.freeze

  def up
    add_column target_table_name(:users), :default_item_tax_inclusion, :string, limit: 5, null: false, default: "gross"
    add_column target_table_name(:receipts), :calculation_settings, :jsonb
    add_column target_table_name(:receipt_items), :input_tax_inclusion, :string, limit: 5
    add_column target_table_name(:receipt_items), :tax_inclusion_origin, :string, limit: 24
    add_column target_table_name(:receipt_items), :gross_line_total, :bigint

    check_constraints.each do |table, constraints|
      definitions = constraints.map do |name, expression|
        "ADD CONSTRAINT #{quote_column_name(name)} CHECK (#{expression}) NOT VALID"
      end.join(", ")

      execute "ALTER TABLE #{quote_table_name(target_table_name(table))} #{definitions}"
    end
  end

  def down
    lock_source_tables!
    refuse_source_data_loss!

    check_constraints.each do |table, constraints|
      constraints.each_key do |name|
        remove_check_constraint target_table_name(table), name: name
      end
    end
    remove_column target_table_name(:receipt_items), :gross_line_total
    remove_column target_table_name(:receipt_items), :tax_inclusion_origin
    remove_column target_table_name(:receipt_items), :input_tax_inclusion
    remove_column target_table_name(:receipts), :calculation_settings
    remove_column target_table_name(:users), :default_item_tax_inclusion
  end

  private

  def target_table_name(table)
    table
  end

  def check_constraints
    {
      users: {
        "check_users_default_item_tax_inclusion" => "default_item_tax_inclusion IN ('gross', 'net')"
      },
      receipts: {
        "check_receipts_calculation_settings" => calculation_settings_constraint
      },
      receipt_items: {
        "check_receipt_items_input_tax_inclusion" => "input_tax_inclusion IS NULL OR input_tax_inclusion IN ('gross', 'net')",
        "check_receipt_items_tax_inclusion_origin" => "tax_inclusion_origin IS NULL OR tax_inclusion_origin IN (#{quoted_values(ORIGINS)})",
        "check_receipt_items_input_tax_inclusion_state" => input_tax_inclusion_state_constraint,
        "check_receipt_items_gross_line_total" => "gross_line_total IS NULL OR gross_line_total BETWEEN 0 AND 999999999999"
      }
    }
  end

  def calculation_settings_constraint
    entries = SETTING_VALUES.map do |key, values|
      entry = "calculation_settings -> '#{key}'"
      <<~SQL.squish
        (
          NOT (calculation_settings ? '#{key}')
          OR (
            jsonb_typeof(#{entry}) = 'object'
            AND (#{entry}) - ARRAY['value', 'origin']::text[] = '{}'::jsonb
            AND jsonb_typeof(#{entry} -> 'value') = 'string'
            AND jsonb_typeof(#{entry} -> 'origin') = 'string'
            AND #{entry} ->> 'value' IN (#{quoted_values(values)})
            AND #{entry} ->> 'origin' IN (#{quoted_values(ORIGINS)})
          )
        )
      SQL
    end.join(" AND ")
    root_keys = quoted_values([ "schema_version", *SETTING_VALUES.keys ])

    <<~SQL.squish
      calculation_settings IS NULL
      OR COALESCE((
        jsonb_typeof(calculation_settings) = 'object'
        AND octet_length(calculation_settings::text) <= 4096
        AND calculation_settings - ARRAY[#{root_keys}]::text[] = '{}'::jsonb
        AND jsonb_typeof(calculation_settings -> 'schema_version') = 'number'
        AND calculation_settings ->> 'schema_version' = '1'
        AND calculation_settings - 'schema_version' <> '{}'::jsonb
        AND #{entries}
      ), FALSE)
    SQL
  end

  def input_tax_inclusion_state_constraint
    <<~SQL.squish
      COALESCE(CASE
        WHEN input_tax_inclusion IS NULL AND tax_inclusion_origin IS NULL
          THEN TRUE
        WHEN pricing_source_kind IN ('count_unit_price', 'explicit_line_total')
          THEN (
            input_tax_inclusion IS NOT NULL
            AND tax_inclusion_origin IS NOT NULL
          )
        WHEN pricing_source_kind = 'reference_quantity_price'
          THEN (
            input_tax_inclusion IS NULL
            AND tax_inclusion_origin IS NOT NULL
            AND reference_price_tax_inclusion IN ('gross', 'net')
          )
        ELSE FALSE
      END, FALSE)
    SQL
  end

  def quoted_values(values)
    values.map { |value| connection.quote(value) }.join(", ")
  end

  def lock_source_tables!
    tables = SOURCE_PREDICATES.keys.map { |table| quote_table_name(target_table_name(table)) }.join(", ")
    execute "LOCK TABLE #{tables} IN ACCESS EXCLUSIVE MODE"
  end

  def refuse_source_data_loss!
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
        "cannot remove recorded calculation settings or gross projections; retain the additive schema"
    end
  end
end
