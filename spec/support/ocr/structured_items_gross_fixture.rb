module StructuredItemsGrossFixture
  private

  def build_structured_items_gross_response(
    item_specs: default_structured_items_gross_item_specs,
    tax_descriptions: [ "内税" ],
    tax_amounts: [ 100 ],
    tax_parenthesized: false,
    total_amount: nil,
    string_index_type: "textElements"
  )
    entries = []
    item_line_ranges = []
    item_specs.each_with_index do |item, item_index|
      start_index = entries.size
      entries.concat([
        item.fetch(:description),
        item.fetch(:price_text),
        item.fetch(:quantity_text),
        item.fetch(:total_text)
      ])
      item_line_ranges << (start_index..entries.size - 1)
    end
    tax_line_ranges = tax_descriptions.map.with_index do |description, index|
      amount = tax_amounts[index]
      start_index = entries.size
      entries << (tax_parenthesized ? "(#{description}" : description)
      entries << (tax_parenthesized ? "¥#{amount})" : "¥#{amount}") unless amount.nil?
      start_index..entries.size - 1
    end
    total_amount ||= item_specs.sum { |item| item.fetch(:total_amount) }
    total_label_index = entries.size
    entries.concat([ "合計", "¥#{total_amount}" ])

    content = entries.join("\n")
    offset = 0
    lines = entries.map.with_index do |line_content, line_index|
      length = structured_items_gross_provider_length(line_content, string_index_type)
      left = line_index == total_label_index + 1 ? 300 : 20
      top = if line_index == total_label_index + 1
        20 + (total_label_index * 24)
      else
        20 + (line_index * 24)
      end
      line = {
        "content" => line_content,
        "boundingRegions" => [
          {
            "pageNumber" => 1,
            "polygon" => [ left, top, left + 180, top, left + 180, top + 16, left, top + 16 ]
          }
        ],
        "polygon" => [ left, top, left + 180, top, left + 180, top + 16, left, top + 16 ],
        "spans" => [ { "offset" => offset, "length" => length } ]
      }
      offset += length + structured_items_gross_provider_length("\n", string_index_type)
      line
    end

    items = item_specs.map.with_index do |item, item_index|
      line_range = item_line_ranges.fetch(item_index)
      first_line = line_range.begin
      last_line = line_range.end
      parent_polygon = structured_items_gross_parent_polygon(lines, line_range)
      {
        "content" => entries.slice(line_range).join("\n"),
        "boundingRegions" => [ { "pageNumber" => 1, "polygon" => parent_polygon } ],
        "spans" => [ structured_items_gross_range(lines, first_line, last_line) ],
        "valueObject" => {
          "Description" => structured_items_gross_string_field(
            lines,
            entries,
            first_line,
            item.fetch(:description)
          ),
          "Price" => structured_items_gross_currency_field(
            lines,
            entries,
            first_line + 1,
            item.fetch(:price_amount)
          ),
          "Quantity" => structured_items_gross_number_field(
            lines,
            entries,
            first_line + 2,
            item.fetch(:quantity_amount)
          ),
          "QuantityUnit" => structured_items_gross_quantity_unit_field(
            lines,
            entries,
            first_line + 2,
            item.fetch(:quantity_unit),
            string_index_type:
          ),
          "TotalPrice" => structured_items_gross_currency_field(
            lines,
            entries,
            last_line,
            item.fetch(:total_amount)
          )
        }
      }
    end

    tax_details = tax_line_ranges.map.with_index do |line_range, tax_detail_index|
      first_line = line_range.begin
      last_line = line_range.end
      amount = tax_amounts[tax_detail_index]
      {
        "content" => entries.slice(line_range).join("\n"),
        "boundingRegions" => [
          { "pageNumber" => 1, "polygon" => structured_items_gross_parent_polygon(lines, line_range) }
        ],
        "spans" => [ structured_items_gross_range(lines, first_line, last_line) ],
        "valueObject" => {
          "Description" => structured_items_gross_tax_description_field(
            lines,
            entries,
            first_line,
            tax_descriptions.fetch(tax_detail_index),
            parenthesized: tax_parenthesized,
            string_index_type:
          ),
          "Amount" => amount.nil? ? nil : structured_items_gross_currency_field(
            lines,
            entries,
            last_line,
            amount
          )
        }.compact
      }
    end

    total_line = lines.fetch(total_label_index + 1)
    total_digits = total_amount.to_s
    total_span = {
      "offset" => total_line.dig("spans", 0, "offset") +
        structured_items_gross_provider_length("¥", string_index_type),
      "length" => structured_items_gross_provider_length(total_digits, string_index_type)
    }

    {
      "status" => "succeeded",
      "analyzeResult" => {
        "modelId" => "prebuilt-receipt",
        "apiVersion" => "2024-11-30",
        "stringIndexType" => string_index_type,
        "content" => content,
        "documents" => [
          {
            "fields" => {
              "Items" => { "type" => "array", "valueArray" => items },
              "TaxDetails" => { "type" => "array", "valueArray" => tax_details },
              "Total" => {
                "content" => total_digits,
                "boundingRegions" => total_line.fetch("boundingRegions").deep_dup,
                "spans" => [ total_span ],
                "valueCurrency" => {
                  "amount" => total_amount.to_f,
                  "currencyCode" => "JPY"
                }
              }
            }
          }
        ],
        "pages" => [
          {
            "pageNumber" => 1,
            "unit" => "pixel",
            "width" => 800,
            "height" => 1_200,
            "lines" => lines
          }
        ]
      }
    }
  end

  def default_structured_items_gross_item_specs
    [
      {
        description: "匿名量売品甲",
        price_text: "240円/100g",
        price_amount: 240,
        quantity_text: "250g",
        quantity_amount: 250,
        quantity_unit: "g",
        total_text: "600円",
        total_amount: 600
      },
      {
        description: "匿名量売品乙",
        price_text: "300円/100g",
        price_amount: 300,
        quantity_text: "200g",
        quantity_amount: 200,
        quantity_unit: "g",
        total_text: "600円",
        total_amount: 600
      }
    ]
  end

  def structured_items_gross_provider_length(value, index_type)
    return value.encode(Encoding::UTF_16LE).bytesize / 2 if index_type == "utf16CodeUnit"

    value.scan(/\X/u).size
  end

  def structured_items_gross_range(lines, first_line, last_line)
    first = lines.fetch(first_line).dig("spans", 0)
    last = lines.fetch(last_line).dig("spans", 0)
    {
      "offset" => first.fetch("offset"),
      "length" => last.fetch("offset") + last.fetch("length") - first.fetch("offset")
    }
  end

  def structured_items_gross_parent_polygon(lines, line_range)
    first = lines.fetch(line_range.begin).fetch("polygon")
    last = lines.fetch(line_range.end).fetch("polygon")
    [ 10, first.fetch(1) - 4, 600, first.fetch(1) - 4, 600, last.fetch(5) + 4, 10, last.fetch(5) + 4 ]
  end

  def structured_items_gross_string_field(lines, entries, line_index, value)
    {
      "content" => entries.fetch(line_index),
      "valueString" => value,
      "boundingRegions" => lines.fetch(line_index).fetch("boundingRegions").deep_dup,
      "spans" => lines.fetch(line_index).fetch("spans").deep_dup
    }
  end

  def structured_items_gross_tax_description_field(
    lines,
    entries,
    line_index,
    value,
    parenthesized:,
    string_index_type:
  )
    field = structured_items_gross_string_field(lines, entries, line_index, value)
    return field unless parenthesized

    field.merge(
      "content" => value,
      "spans" => [
        {
          "offset" => lines.fetch(line_index).dig("spans", 0, "offset") +
            structured_items_gross_provider_length("(", string_index_type),
          "length" => structured_items_gross_provider_length(value, string_index_type)
        }
      ]
    )
  end

  def structured_items_gross_currency_field(lines, entries, line_index, amount)
    {
      "content" => entries.fetch(line_index),
      "valueCurrency" => { "amount" => amount.to_f, "currencyCode" => "JPY" },
      "boundingRegions" => lines.fetch(line_index).fetch("boundingRegions").deep_dup,
      "spans" => lines.fetch(line_index).fetch("spans").deep_dup
    }
  end

  def structured_items_gross_number_field(lines, entries, line_index, amount)
    {
      "content" => entries.fetch(line_index),
      "valueNumber" => amount.to_f,
      "boundingRegions" => lines.fetch(line_index).fetch("boundingRegions").deep_dup,
      "spans" => lines.fetch(line_index).fetch("spans").deep_dup
    }
  end

  def structured_items_gross_quantity_unit_field(
    lines,
    entries,
    line_index,
    unit,
    string_index_type:
  )
    line_content = entries.fetch(line_index)
    prefix = line_content.delete_suffix(unit)
    line_span = lines.fetch(line_index).dig("spans", 0)
    {
      "content" => unit,
      "valueString" => unit,
      "boundingRegions" => lines.fetch(line_index).fetch("boundingRegions").deep_dup,
      "spans" => [
        {
          "offset" => line_span.fetch("offset") +
            structured_items_gross_provider_length(prefix, string_index_type),
          "length" => structured_items_gross_provider_length(unit, string_index_type)
        }
      ]
    }
  end
end
