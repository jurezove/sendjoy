class WebhooksController < ActionController::Base
  skip_before_action :verify_authenticity_token

  def create
    ProcessBogoOrderJob.perform_later(params.permit!.to_h)
    head :ok
  end
end
