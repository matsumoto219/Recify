module Admin
  class SystemSettingFormPresenter
    TEXTAREA_STRING_KEYS = %w[
      ui.maintenance_notice_body
      maintenance.body
    ].freeze

    FieldRender = Struct.new(:partial, :locals, keyword_init: true)

    attr_reader :record

    def initialize(record:, reauthenticated:)
      @record = record
      @reauthenticated = reauthenticated
    end

    def label_class
      "text-xs font-semibold token-text-muted normal-case tracking-normal px-0"
    end

    def control_class
      "rounded-lg text-sm"
    end

    def mono_control_class
      "rounded-lg font-mono text-sm"
    end

    def textarea_control_class
      "rounded-lg text-sm py-2 leading-6"
    end

    def mono_textarea_control_class
      "rounded-lg font-mono text-sm py-2 leading-6"
    end

    def readonly?
      record[:editable] != true
    end

    def reauthentication_required?
      !readonly? && !reauthenticated?
    end

    def editable?
      !readonly? && reauthenticated?
    end

    def requires_confirmation?
      record[:requires_confirmation] == true
    end

    def value_field_render(form:)
      case record[:value_type].to_s
      when "boolean"
        boolean_field(form)
      when "integer", "duration"
        integer_field(form)
      when "decimal", "percentage"
        decimal_field(form)
      when "enum"
        enum_field(form)
      when "user_allowlist"
        user_allowlist_field(form)
      when "feature_flag"
        feature_flag_field(form)
      when "string"
        string_field(form)
      else
        text_field(form)
      end
    end

    private

    def reauthenticated?
      @reauthenticated == true
    end

    def current_value
      record[:current_value]
    end

    def base_locals(form)
      {
        f: form,
        attribute: :value,
        label: I18n.t("admin.system_settings.show.update.value_label"),
        with_icon: false,
        label_class: label_class
      }
    end

    def boolean_field(form)
      FieldRender.new(
        partial: "shared/ui/form/select_field",
        locals: base_locals(form).merge(
          options: [
            [ I18n.t("admin.system_settings.show.update.enabled"), "true" ],
            [ I18n.t("admin.system_settings.show.update.disabled"), "false" ]
          ],
          selected: current_value.to_s,
          size: :dense,
          select_class: control_class
        )
      )
    end

    def integer_field(form)
      FieldRender.new(
        partial: "shared/ui/form/number_field",
        locals: base_locals(form).merge(
          value: current_value,
          min: record[:min],
          max: record[:max],
          step: 1,
          required: true,
          size: :dense,
          text_align: :left,
          input_class: control_class
        )
      )
    end

    def decimal_field(form)
      FieldRender.new(
        partial: "shared/ui/form/number_field",
        locals: base_locals(form).merge(
          value: current_value,
          min: record[:min],
          max: record[:max],
          step: :any,
          required: true,
          size: :dense,
          text_align: :left,
          input_class: control_class
        )
      )
    end

    def enum_field(form)
      FieldRender.new(
        partial: "shared/ui/form/select_field",
        locals: base_locals(form).merge(
          options: Array(record[:allowed_values]).map { |value| [ value, value ] },
          selected: current_value.to_s,
          size: :dense,
          select_class: control_class
        )
      )
    end

    def user_allowlist_field(form)
      FieldRender.new(
        partial: "shared/ui/form/textarea_field",
        locals: base_locals(form).merge(
          value: Array(current_value).join("\n"),
          rows: 5,
          textarea_class: textarea_control_class
        )
      )
    end

    def feature_flag_field(form)
      FieldRender.new(
        partial: "shared/ui/form/textarea_field",
        locals: base_locals(form).merge(
          value: JSON.pretty_generate(current_value),
          rows: 8,
          textarea_class: mono_textarea_control_class
        )
      )
    end

    def string_field(form)
      return textarea_string_field(form) if TEXTAREA_STRING_KEYS.include?(record[:key].to_s)

      text_field(form)
    end

    def textarea_string_field(form)
      FieldRender.new(
        partial: "shared/ui/form/textarea_field",
        locals: base_locals(form).merge(
          value: current_value,
          rows: 5,
          size: :dense,
          textarea_class: textarea_control_class,
          html_options: string_html_options
        )
      )
    end

    def text_field(form)
      FieldRender.new(
        partial: "shared/ui/form/text_field",
        locals: base_locals(form).merge(
          value: current_value,
          size: :dense,
          input_class: control_class,
          html_options: string_html_options
        )
      )
    end

    def string_html_options
      return {} if record[:max].blank?

      { maxlength: record[:max] }
    end
  end
end
