module Admin
  module JsonHelper
    def admin_pretty_json(value)
      JSON.pretty_generate(value)
    end
  end
end
