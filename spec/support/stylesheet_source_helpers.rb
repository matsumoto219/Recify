require "pathname"

module StylesheetSourceHelpers
  def expanded_tailwind_source
    root = Pathname(File.expand_path("../../app/assets/tailwind", __dir__))
    seen = {}
    read_stylesheet = lambda do |path|
      expanded_path = Pathname(path).expand_path
      return "" if seen[expanded_path.to_s]

      seen[expanded_path.to_s] = true
      expanded_path.read.gsub(%r{^@import "\./([^"]+)";}) do
        read_stylesheet.call(root.join(Regexp.last_match(1)))
      end
    end

    read_stylesheet.call(root.join("application.css"))
  end
end
