require 'slack-ruby-client'
require 'shopify_api'

class ProcessBogoOrderJob < ApplicationJob
  queue_as :default

  def perform(order_params)
    order = order_params.with_indifferent_access
    if bogo_product?(order)
      process_bogo_order(order)
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
    billing_address = order['billing_address']&.[]('address1')

    recipient_address.downcase == billing_address&.downcase
  end

  def create_gift_order(original_order)
    bogo_item = original_order['line_items'].find { |item| item['product_id'].to_s == ENV['BOGO_PRODUCT_ID'] }
    return unless bogo_item

    shop_url = ENV['SHOPIFY_SHOP_URL']
    access_token = ENV['SHOPIFY_ACCESS_TOKEN']
    gift_product_id = ENV['GIFT_PRODUCT_ID']

    session = ShopifyAPI::Auth::Session.new(shop: shop_url, access_token: access_token)
    client = ShopifyAPI::Clients::Rest::Admin.new(session: session)

    # Fetch the gift product to get its first variant
    gift_product_response = client.get(path: "products/#{gift_product_id}.json")
    
    if gift_product_response.ok?
      gift_product = gift_product_response.body['product']
      gift_variant = gift_product['variants'].first
    else
      raise "Failed to fetch gift product: #{gift_product_response.errors.full_messages.join(', ')}"
    end

    # Parse first and last name
    full_name = find_property(bogo_item, 'Recipient Name')
    first_name, last_name = parse_name(full_name)

    new_order = {
      email: original_order['email'],
      shipping_address: {
        first_name: first_name,
        last_name: last_name,
        address1: find_property(bogo_item, 'Recipient Address'),
        city: find_property(bogo_item, 'Recipient City'),
        province: find_property(bogo_item, 'Recipient City'),  # Using City for province as we don't have separate province info
        zip: find_property(bogo_item, 'Recipient ZIP'),
        country: find_property(bogo_item, 'Recipient Country') || ENV['DEFAULT_GIFT_ORDER_COUNTRY'],
        phone: find_property(bogo_item, 'Recipient Phone')
      },
      line_items: [
        {
          variant_id: gift_variant['id'],
          quantity: 1,
          price: '0.00'
        }
      ],
      financial_status: 'paid',
      tags: 'BOGO Gift',
      note: "This is a gifted item from a Buy One, Gift One promotion. Original Order ID: #{original_order['id']}",
      shipping_lines: [
        {
          price: '0.00',
          title: 'Free Shipping'
        }
      ]
    }

    begin
      response = client.post(
        path: 'orders.json',
        body: { order: new_order }
      )
      
      if response.ok?
        created_order = response.body['order']
        Rails.logger.info "Gift order created: #{created_order['id']}"
        notify_slack(original_order, is_bogo: true, gift_order_id: created_order['id'])
      else
        raise "Failed to create order: #{response.errors.full_messages.join(', ')}"
      end
    rescue StandardError => e
      Rails.logger.error "Error creating gift order: #{e.message}"
      notify_slack(original_order, is_bogo: true, error: e.message)
    end
  end

  def notify_slack(order, is_bogo:, fraud_suspected: false, error: nil, gift_order_id: nil)
    client = Slack::Web::Client.new(token: ENV['SLACK_BOT_TOKEN'])

    message = {
      channel: ENV['SLACK_CHANNEL_ID'],
      text: is_bogo ? "Palo Santo For a Friend sold!" : "New order received",
      blocks: [
        {
          type: "section",
          text: {
            type: "mrkdwn",
            text: is_bogo ? "*Palo Santo For a Friend order received!*" : "*New order received*"
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
              text: "*Purchaser:*\n#{order['billing_address']&.[]('first_name')} #{order['billing_address']&.[]('last_name')}\n#{order['billing_address']&.[]('address1')}, #{order['billing_address']&.[]('city')}"
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
            text: "*Recipient:*\n#{find_property(bogo_item, 'Recipient Name')}, #{find_property(bogo_item, 'Recipient Address')}, #{find_property(bogo_item, 'Recipient City')}, #{find_property(bogo_item, 'Recipient Country')}"
          }
        ]
      }
      message[:blocks].insert(-1, recipient_info)

      if gift_order_id
        gift_order_info = {
          type: "section",
          text: {
            type: "mrkdwn",
            text: "*Gift Order Created:* ID #{gift_order_id}"
          }
        }
        message[:blocks].insert(-1, gift_order_info)
      end

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

      if error
        error_message = {
          type: "section",
          text: {
            type: "mrkdwn",
            text: ":x: *Error creating gift order:* #{error}"
          }
        }
        message[:blocks].insert(-1, error_message)
      end
    end

    client.chat_postMessage(message)
  end

  def find_property(line_item, property_name)
    property = line_item['properties'].find { |prop| prop['name'] == property_name }
    property ? property['value'] : nil
  end

  def parse_name(full_name)
    name_parts = full_name.split
    if name_parts.size > 1
      last_name = name_parts.pop
      first_name = name_parts.join(' ')
    else
      first_name = full_name
      last_name = ''
    end
    [first_name, last_name]
  end
end