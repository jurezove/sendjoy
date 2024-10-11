class WebhooksController < ActionController::Base
  skip_before_action :verify_authenticity_token

  def create
    webhook_payload = JSON.parse(request.body.read)
    ProcessBogoOrderJob.perform_later(webhook_payload)
    head :ok
  end
end
