module Admin
  module TableHelper
    TABLE_SIZE_CLASSES = {
      sm: "min-w-[40rem]",
      md: "min-w-[56rem]",
      lg: "min-w-[72rem]",
      xl: "min-w-[80rem]",
      xxl: "min-w-[96rem]"
    }.freeze

    TABLE_CELL_TYPE_CLASSES = {
      id: "font-mono text-xs whitespace-nowrap",
      long_id: "font-mono text-xs whitespace-nowrap min-w-[18rem]",
      datetime: "whitespace-nowrap min-w-[8rem]",
      status: "whitespace-nowrap min-w-[7rem]",
      action: "whitespace-nowrap min-w-[5rem]",
      subject: "min-w-[16rem] max-w-xs truncate",
      email: "font-mono text-xs whitespace-nowrap min-w-[14rem]",
      long_text: "min-w-[18rem] max-w-md break-words [overflow-wrap:anywhere]"
    }.freeze

    def admin_table_classes(size: :md, extra_class: nil)
      table_size = TABLE_SIZE_CLASSES.fetch(size.to_sym)

      [ "min-w-full text-left text-sm", table_size, extra_class ].compact.join(" ")
    end

    def admin_table_cell_classes(type:, extra_class: nil)
      cell_type = TABLE_CELL_TYPE_CLASSES.fetch(type.to_sym)

      [ cell_type, extra_class ].compact.join(" ")
    end
  end
end
