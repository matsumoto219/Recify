module Admin
  module JsonHelper
    def admin_json_container_classes(extra_class: nil)
      [ "min-w-0 max-w-full", extra_class ].compact.join(" ")
    end

    def admin_json_pre_classes(details: false, extra_class: nil)
      overflow_class = details ? "max-h-[32rem] overflow-auto" : "overflow-x-auto"

      [
        "max-w-full whitespace-pre rounded-lg token-bg-input token-border-soft border p-4 text-xs token-text-base",
        overflow_class,
        extra_class
      ].compact.join(" ")
    end

    def admin_pretty_json(value)
      JSON.pretty_generate(value)
    end
  end
end
