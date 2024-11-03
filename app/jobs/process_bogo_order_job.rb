require 'slack-ruby-client'
require 'shopify_api'

class ProcessBogoOrderJob < ApplicationJob
  queue_as :default

  def perform(order_params)
    order = order_params.with_indifferent_access
    Rails.logger.info "ProcessBogoOrderJob started with order: #{order['id']}"
    
    unless order['financial_status'] == 'paid'
      Rails.logger.info "Order #{order['id']} is not paid (status: #{order['financial_status']}). Skipping BOGO processing."
      return
    end
    
    if bogo_product?(order)
      Rails.logger.info "BOGO product found in order #{order['id']}"
      process_bogo_order(order)
    else
      Rails.logger.info "No BOGO product found in order #{order['id']}"
    end
  end

  private

  def bogo_product?(order)
    order['line_items'].any? { |item| item['product_id'].to_s == ENV['BOGO_PRODUCT_ID'] }
  end

  def process_bogo_order(order)
    if fraud_suspected?(order)
      Rails.logger.warn "Fraud suspected for order #{order['id']}"
      notify_slack(order, is_bogo: true, fraud_suspected: true)
    else
      create_gift_order(order)
      notify_slack(order, is_bogo: true, fraud_suspected: false)
    end
  end

  def normalize_phone(phone)
    return nil unless phone
    # Remove all non-digit characters and get last 10 digits
    phone.gsub(/\D/, '').gsub(/\A\+?1/, '').last(8)
  end

  def addresses_match?(address1, address2)
    return false unless address1 && address2
    address1.downcase == address2.downcase
  end

  def phones_match?(phone1, phone2)
    normalized1 = normalize_phone(phone1)
    normalized2 = normalize_phone(phone2)
    
    return false if normalized1.nil? || normalized2.nil?
    return true if normalized1 == normalized2

    # Log the comparison for debugging
    Rails.logger.info "Phone number comparison:"
    Rails.logger.info "  Original: #{phone1} -> #{normalized1}"
    Rails.logger.info "  Recipient: #{phone2} -> #{normalized2}"
    
    false
  end

  def fraud_suspected?(order)
    bogo_item = order['line_items'].find { |item| item['product_id'].to_s == ENV['BOGO_PRODUCT_ID'] }
    return false unless bogo_item

    recipient_address = find_property(bogo_item, 'Recipient Address')
    recipient_phone = find_property(bogo_item, 'Recipient Phone')
    
    billing_address = order['billing_address']&.[]('address1')
    billing_phone = order['billing_address']&.[]('phone')

    address_match = addresses_match?(recipient_address, billing_address)
    phone_match = phones_match?(recipient_phone, billing_phone)

    if address_match || phone_match
      Rails.logger.warn "Potential fraud detected for order #{order['id']}:"
      Rails.logger.warn "  Address match: #{address_match}"
      Rails.logger.warn "  Phone match: #{phone_match}"
      Rails.logger.warn "  Recipient address: #{recipient_address}"
      Rails.logger.warn "  Billing address: #{billing_address}"
      Rails.logger.warn "  Recipient phone: #{recipient_phone}"
      Rails.logger.warn "  Billing phone: #{billing_phone}"
    end

    address_match || phone_match
  end

  def create_gift_order(original_order)
    Rails.logger.info "Creating gift order for original order: #{original_order['id']}"
    
    bogo_item = original_order['line_items'].find { |item| item['product_id'].to_s == ENV['BOGO_PRODUCT_ID'] }
    unless bogo_item
      Rails.logger.error "BOGO item not found in order #{original_order['id']}"
      return
    end

    Rails.logger.info "Found BOGO item in order: #{bogo_item.inspect}"

    shop_url = ENV['SHOPIFY_SHOP_URL']
    access_token = ENV['SHOPIFY_ACCESS_TOKEN']
    gift_product_id = ENV['GIFT_PRODUCT_ID']

    Rails.logger.info "Creating Shopify session with shop URL: #{shop_url}"
    session = ShopifyAPI::Auth::Session.new(shop: shop_url, access_token: access_token)
    client = ShopifyAPI::Clients::Rest::Admin.new(session: session)

    # Fetch the gift product to get its first variant
    Rails.logger.info "Fetching gift product details for ID: #{gift_product_id}"
    gift_product_response = client.get(path: "products/#{gift_product_id}.json")
    
    if gift_product_response.ok?
      gift_product = gift_product_response.body['product']
      gift_variant = gift_product['variants'].first
      Rails.logger.info "Found gift product variant: #{gift_variant.inspect}"
    else
      error_message = "Failed to fetch gift product: #{gift_product_response.errors.full_messages.join(', ')}"
      Rails.logger.error error_message
      raise error_message
    end

    # Parse first and last name
    full_name = find_property(bogo_item, 'Recipient Name')
    first_name, last_name = parse_name(full_name)
    
    # Log all recipient properties
    Rails.logger.info "Recipient Information:"
    Rails.logger.info "  Full Name: #{full_name}"
    Rails.logger.info "  Parsed Name: #{first_name} #{last_name}"
    Rails.logger.info "  Address: #{find_property(bogo_item, 'Recipient Address')}"
    Rails.logger.info "  City: #{find_property(bogo_item, 'Recipient City')}"
    Rails.logger.info "  ZIP: #{find_property(bogo_item, 'Recipient ZIP')}"
    Rails.logger.info "  Country: #{find_property(bogo_item, 'Recipient Country')}"
    Rails.logger.info "  Phone: #{find_property(bogo_item, 'Recipient Phone')}"

    shipping_address = {
      first_name: first_name,
      last_name: last_name,
      address1: find_property(bogo_item, 'Recipient Address'),
      city: find_property(bogo_item, 'Recipient City'),
      province: find_property(bogo_item, 'Recipient City'),  # Using City for province as we don't have separate province info
      zip: find_property(bogo_item, 'Recipient ZIP'),
      country: find_property(bogo_item, 'Recipient Country').presence || ENV['DEFAULT_GIFT_ORDER_COUNTRY'],
      phone: find_property(bogo_item, 'Recipient Phone')
    }

    Rails.logger.info "Constructed shipping address: #{shipping_address.inspect}"

    new_order = {
      shipping_address: shipping_address,
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

    Rails.logger.info "Attempting to create gift order with payload:"
    Rails.logger.info JSON.pretty_generate(new_order)

    begin
      Rails.logger.info "Sending gift order creation request to Shopify"
      response = client.post(
        path: 'orders.json',
        body: { order: new_order }
      )
      
      if response.ok?
        created_order = response.body['order']
        Rails.logger.info "Gift order created successfully:"
        Rails.logger.info JSON.pretty_generate(created_order)
        notify_slack_gift_order(original_order, created_order['id'])
      else
        error_message = "Failed to create order: #{response.errors.full_messages.join(', ')}"
        Rails.logger.error "Gift order creation failed with errors:"
        Rails.logger.error JSON.pretty_generate(response.errors)
        raise error_message
      end
    rescue StandardError => e
      Rails.logger.error "Exception while creating gift order: #{e.message}"
      Rails.logger.error "Backtrace: #{e.backtrace.join("\n")}"
      notify_slack(original_order, is_bogo: true, error: e.message)
    end
  end

  def get_order_url(order_id)
    "https://admin.shopify.com/store/#{ENV['SHOPIFY_SHOP_URL']}/orders/#{order_id}"
  end

  def notify_slack_gift_order(original_order, gift_order_id)
    client = Slack::Web::Client.new(token: ENV['SLACK_BOT_TOKEN'])
    bogo_item = original_order['line_items'].find { |item| item['product_id'].to_s == ENV['BOGO_PRODUCT_ID'] }

    message = {
      channel: ENV['SLACK_CHANNEL_ID'],
      text: "🎁 Gift Order Created!",
      blocks: [
        {
          type: "section",
          text: {
            type: "mrkdwn",
            text: "*🎁 Gift Order Successfully Created!*"
          }
        },
        {
          type: "section",
          fields: [
            {
              type: "mrkdwn",
              text: "*Original Order:*\n<#{get_order_url(original_order['id'])}|##{original_order['id']}>"
            },
            {
              type: "mrkdwn",
              text: "*Gift Order:*\n<#{get_order_url(gift_order_id)}|##{gift_order_id}>"
            }
          ]
        },
        {
          type: "section",
          fields: [
            {
              type: "mrkdwn",
              text: "*From:*\n#{original_order['billing_address']&.[]('first_name')} #{original_order['billing_address']&.[]('last_name')}"
            },
            {
              type: "mrkdwn",
              text: "*To:*\n#{find_property(bogo_item, 'Recipient Name')}"
            }
          ]
        },
        {
          type: "section",
          fields: [
            {
              type: "mrkdwn",
              text: "*Shipping To:*\n#{find_property(bogo_item, 'Recipient Address')}\n#{find_property(bogo_item, 'Recipient City')}, #{find_property(bogo_item, 'Recipient Country')}"
            }
          ]
        }
      ]
    }

    client.chat_postMessage(message)
  end

  def notify_slack(order, is_bogo:, fraud_suspected: false, error: nil, gift_order_id: nil)
    return if gift_order_id  # Skip if this is a successful gift order (handled by notify_slack_gift_order)
    
    client = Slack::Web::Client.new(token: ENV['SLACK_BOT_TOKEN'])

    message = {
      channel: ENV['SLACK_CHANNEL_ID'],
      text: "New Palo Santo For a Friend order!",
      blocks: [
        {
          type: "section",
          text: {
            type: "mrkdwn",
            text: "*New Palo Santo For a Friend Order Received! 🌿*"
          }
        },
        {
          type: "section",
          fields: [
            {
              type: "mrkdwn",
              text: "*Order ID:*\n<#{get_order_url(order['id'])}|##{order['id']}>"
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
              text: "*Purchased By:*\n#{order['billing_address']&.[]('first_name')} #{order['billing_address']&.[]('last_name')}\n#{order['billing_address']&.[]('address1')}, #{order['billing_address']&.[]('city')}"
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
            text: "*Will be Gifted To:*\n#{find_property(bogo_item, 'Recipient Name')}\n#{find_property(bogo_item, 'Recipient Address')}, #{find_property(bogo_item, 'Recipient City')}, #{find_property(bogo_item, 'Recipient Country')}"
          }
        ]
      }
      message[:blocks].insert(-1, recipient_info)
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
