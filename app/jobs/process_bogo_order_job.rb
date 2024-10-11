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
    # Implement logic to check if the order contains a BOGO product
    # This is a placeholder implementation
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
    # Implement your fraud detection logic here
    # For now, we'll return false as a placeholder
    false
  end

  def create_gift_order(original_order)
    # Implement gift order creation logic
    # This is a placeholder implementation
    Rails.logger.info "Creating gift order for order #{original_order['id']}"
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
      bogo_info = {
        type: "section",
        text: {
          type: "mrkdwn",
          text: "*BOGO Product:*\nBOGO product found in order"
        }
      }
      message[:blocks].insert(-1, bogo_info)

      if fraud_suspected
        fraud_warning = {
          type: "section",
          text: {
            type: "mrkdwn",
            text: ":warning: *Potential fraud detected*"
          }
        }
        message[:blocks].insert(-1, fraud_warning)
      end
    end

    client.chat_postMessage(message)
  end
end
