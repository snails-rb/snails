module Api
  # The scaffold's controller base — app-wide behavior lands here. Dispatch and
  # the before_action chain come from ActionController::API.
  class ApplicationController < ActionController::API
    JSON_TYPE = "application/json; charset=utf-8"

    # A missing record is a 404 for every action and before-filter from one
    # place: the raising finders (`find` / `find_by!`) surface
    # `Sqlx::RecordNotFound`, and this rescue answers it the same way each time
    # instead of each action checking for nil.
    def process_action(action_name)
      super
    rescue Sqlx::RecordNotFound
      handle_record_not_found
    end

    private

    # The one 404 answer. Override this to customize the not-found response
    # (a JSON error body, a problem document) without touching each action.
    def handle_record_not_found
      head(:not_found, content_type: JSON_TYPE)
    end
  end
end
