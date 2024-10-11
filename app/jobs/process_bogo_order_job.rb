require 'slack-ruby-client'

class ProcessBogoOrderJob < ApplicationJob
  queue_as :default

  def perform(webhook_payload)
    order = webhook_payload['order']

    if bogo_product?(order)
      process_bogo_order(order)
    else
      notify_slack(order, is_bogo: false)
    end
  end

  private

  def bogo_product?(order)
    # Implement logic to check if the order contains a BOGO product
    # This is a placeholder implementation
    order['line_items'].any? { |item| item['product_id'] == ENV['BOGO_PRODUCT_ID'] }
  end

  def process_bogo_order(order)
    if fraud_suspected?(order)
      notify_slack(order, is_bogo: true, fraud_suspected: true)
    else
      create_gift_order(order)
      notify_slack(order, is_bogo: true, fraud_suspected: false)
    end
  end

  def fraud_suspected?(order)
    # Compare the original shipping address with the gift recipient's address
    original_address = order['shipping_address']
    recipient_address = {
      'address1' => find_property(order, 'recipient_address1'),
      'city' => find_property(order, 'recipient_city'),
      'zip' => find_property(order, 'recipient_zip')
    }

    original_address['address1'] == recipient_address['address1'] &&
      original_address['city'] == recipient_address['city'] &&
      original_address['zip'] == recipient_address['zip']
  end

  def create_gift_order(original_order)
    shop_url = ENV['SHOPIFY_SHOP_URL']
    access_token = ENV['SHOPIFY_ACCESS_TOKEN']

    ShopifyAPI::Base.site = "https://#{shop_url}/admin"
    ShopifyAPI::Base.headers['X-Shopify-Access-Token'] = access_token

    # Find the BOGO product in the original order
    bogo_line_item = original_order['line_items'].find { |item| item['product_id'] == ENV['BOGO_PRODUCT_ID'] }
    return unless bogo_line_item

    # Create a new order for the gift recipient
    new_order = ShopifyAPI::Order.new(
      email: original_order['email'],
      shipping_address: {
        first_name: find_property(original_order, 'recipient_first_name'),
        last_name: find_property(original_order, 'recipient_last_name'),
        address1: find_property(original_order, 'recipient_address1'),
        city: find_property(original_order, 'recipient_city'),
        province: find_property(original_order, 'recipient_province'),
        country: find_property(original_order, 'recipient_country'),
        zip: find_property(original_order, 'recipient_zip'),
        phone: find_property(original_order, 'recipient_phone')
      },
      line_items: [
        {
          variant_id: bogo_line_item['variant_id'],
          quantity: 1,
          price: '0.00' # Set price to 0 for the gifted item
        }
      ],
      financial_status: 'paid',
      tags: 'BOGO Gift',
      note: 'This is a gifted item from a Buy One, Gift One promotion.'
    )
    new_order.save
  end

  def notify_slack(order, is_bogo:, fraud_suspected: false)
    client = Slack::Web::Client.new(token: ENV['SLACK_BOT_TOKEN'])

    message = {
      channel: ENV['SLACK_CHANNEL_ID'],
      text: is_bogo ? "BOGO product order received!" : "New order received (non-BOGO)",
      blocks: [
        {
          type: "section",
          text: {
            type: "mrkdwn",
            text: is_bogo ? "*BOGO product order received!*" : "*New order received (non-BOGO)*"
          }
        },
        {
          type: "section",
          fields: [
            {
              type: "mrkdwn",
              text: "*Order ID:*\n#{order['id']}"
            },
            {
              type: "mrkdwn",
              text: "*Total Price:*\n#{order['total_price']} #{order['currency']}"
            }
          ]
        },
        {
          type: "section",
          fields: [
            {
              type: "mrkdwn",
              text: "*Purchaser:*\n#{order['shipping_address']['address1']}, #{order['shipping_address']['city']}"
            }
          ]
        }
      ]
    }

    if is_bogo
      recipient_info = {
        type: "section",
        fields: [
          {
            type: "mrkdwn",
            text: "*Recipient:*\n#{find_property(order, 'recipient_address1')}, #{find_property(order, 'recipient_city')}"
          }
        ]
      }
      message[:blocks].insert(-1, recipient_info)

      if fraud_suspected
        fraud_warning = {
          type: "section",
          text: {
            type: "mrkdwn",
            text: ":warning: *Potential fraud detected:* Recipient address matches purchaser address."
          }
        }
        message[:blocks].insert(-1, fraud_warning)
      end
    end

    client.chat_postMessage(message)
  end

  def find_property(order, property_name)
    order['properties'].find { |prop| prop['name'] == property_name }&.dig('value')
  end
end