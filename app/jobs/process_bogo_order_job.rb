class ProcessBogoOrderJob < ApplicationJob
  queue_as :default

  def perform(webhook_payload)
    order = webhook_payload['order']
    return unless bogo_product?(order)
    return if fraud_suspected?(order)

    create_gift_order(order)
    notify_slack(order)
  end

  private

  def bogo_product?(order)
    # Implement logic to check if the order contains a BOGO product
    # This is a placeholder implementation
    order['line_items'].any? { |item| item['product_id'] == ENV['BOGO_PRODUCT_ID'] }
  end

  def fraud_suspected?(order)
    recipient_address = order['shipping_address']
    billing_address = order['billing_address']

    recipient_address == billing_address
  end

  def create_gift_order(original_order)
    # Implement Shopify API call to create a new order
    # This is a placeholder implementation
    shop_url = ENV['SHOPIFY_SHOP_URL']
    access_token = ENV['SHOPIFY_ACCESS_TOKEN']

    ShopifyAPI::Base.site = "https://#{shop_url}/admin"
    ShopifyAPI::Base.headers['X-Shopify-Access-Token'] = access_token

    new_order = ShopifyAPI::Order.new(
      email: original_order['email'],
      shipping_address: original_order['shipping_address'],
      line_items: original_order['line_items'],
      financial_status: 'paid',
      total_discounts: original_order['total_price'],
      tags: 'BOGO Gift'
    )
    new_order.save
  end

  def notify_slack(order)
    client = Slack::Web::Client.new(token: ENV['SLACK_BOT_TOKEN'])

    message = {
      channel: ENV['SLACK_CHANNEL_ID'],
      text: "BOGO product sold!",
      blocks: [
        {
          type: "section",
          text: {
            type: "mrkdwn",
            text: "*BOGO product sold!*"
          }
        },
        {
          type: "section",
          fields: [
            {
              type: "mrkdwn",
              text: "*Purchaser:*\n#{order['billing_address']['address1']}, #{order['billing_address']['city']}"
            },
            {
              type: "mrkdwn",
              text: "*Recipient:*\n#{order['shipping_address']['address1']}, #{order['shipping_address']['city']}"
            }
          ]
        }
      ]
    }

    client.chat_postMessage(message)
  end
end