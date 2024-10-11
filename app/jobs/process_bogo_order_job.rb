class ProcessBogoOrderJob < ApplicationJob
  queue_as :default

  def perform(order)
    if bogo_product?(order)
      process_bogo_order(order)
    else
      notify_slack(order, is_bogo: false)
    end
  end

  private

  def bogo_product?(order)
    order['line_items'].any? { |item| item['product_id'].to_s == ENV['BOGO_PRODUCT_ID'] }
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
    bogo_item = order['line_items'].find { |item| item['product_id'].to_s == ENV['BOGO_PRODUCT_ID'] }
    return false unless bogo_item

    recipient_address = find_property(bogo_item, 'Recipient Address')
    billing_address = order['billing_address']['address1']

    recipient_address.downcase == billing_address.downcase
  end

  def create_gift_order(original_order)
    bogo_item = original_order['line_items'].find { |item| item['product_id'].to_s == ENV['BOGO_PRODUCT_ID'] }
    return unless bogo_item

    shop_url = ENV['SHOPIFY_SHOP_URL']
    access_token = ENV['SHOPIFY_ACCESS_TOKEN']

    ShopifyAPI::Base.site = "https://#{shop_url}/admin"
    ShopifyAPI::Base.headers['X-Shopify-Access-Token'] = access_token

    new_order = ShopifyAPI::Order.new(
      email: original_order['email'],
      shipping_address: {
        first_name: find_property(bogo_item, 'Recipient Name'),
        address1: find_property(bogo_item, 'Recipient Address'),
        city: original_order['billing_address']['city'],
        province: original_order['billing_address']['province'],
        country: original_order['billing_address']['country'],
        zip: original_order['billing_address']['zip'],
        phone: original_order['billing_address']['phone']
      },
      line_items: [
        {
          variant_id: bogo_item['variant_id'],
          quantity: 1,
          price: '0.00'
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
              text: "*Purchaser:*\n#{order['billing_address']['address1']}, #{order['billing_address']['city']}"
            }
          ]
        }
      ]
    }

    if is_bogo
      bogo_item = order['line_items'].find { |item| item['product_id'].to_s == ENV['BOGO_PRODUCT_ID'] }
      recipient_info = {
        type: "section",
        fields: [
          {
            type: "mrkdwn",
            text: "*Recipient:*\n#{find_property(bogo_item, 'Recipient Name')}, #{find_property(bogo_item, 'Recipient Address')}"
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

  def find_property(line_item, property_name)
    property = line_item['properties'].find { |prop| prop['name'] == property_name }
    property ? property['value'] : nil
  end
end
