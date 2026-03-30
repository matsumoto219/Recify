class AiReceiptService
  def self.call(receipt)
    {
      store_name: "サンプルストア",
      purchased_at: Time.current,
      total_amount: 1280,
      payment_method: "credit_card",
      status: "review_needed",
      items: [
        {
          raw_text: "ｺｰﾋｰ",
          suggested_name: "コーヒー",
          confirmed_name: "コーヒー",
          category: "飲料",
          price: 180,
          quantity: 1,
          line_total: 180,
          needs_review: false,
          position_index: 1,
          confidence: 0.95
        },
        {
          raw_text: "ｻﾝﾄﾞ",
          suggested_name: "サンドイッチ",
          confirmed_name: "サンドイッチ",
          category: "食品",
          price: 550,
          quantity: 2,
          line_total: 1100,
          needs_review: true,
          position_index: 2,
          confidence: 0.72
        }
      ]
    }
  end
end
