# frozen_string_literal: true

require "cgi"

module GeneratedReceipts
  class HtmlRenderer
    def self.call(case_data)
      new(case_data).call
    end

    def initialize(case_data)
      @case_data = case_data
      @render = case_data.fetch("render", {})
    end

    def call
      width = render["paper_width"] == "80mm" ? 420 : 320
      escaped_text = CGI.escapeHTML(TextRenderer.call(case_data))

      <<~HTML
        <!doctype html>
        <html lang="ja">
        <head>
          <meta charset="utf-8">
          <style>
            html, body {
              margin: 0;
              padding: 0;
              background: #f2f2f2;
            }

            #receipt {
              box-sizing: border-box;
              width: #{width}px;
              min-height: 100px;
              padding: 20px 18px 24px;
              background: #fff;
              color: #111;
              font-family: "Hiragino Sans", "Yu Gothic", "Noto Sans CJK JP", "Meiryo", monospace;
              font-size: 16px;
              font-weight: 500;
              line-height: 1.45;
              white-space: pre-wrap;
              letter-spacing: 0;
              -webkit-font-smoothing: antialiased;
            }
          </style>
        </head>
        <body>
          <pre id="receipt">#{escaped_text}</pre>
        </body>
        </html>
      HTML
    end

    private

    attr_reader :case_data, :render
  end
end
