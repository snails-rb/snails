# Route-declaration DSL — the verb helpers and the RESTful expansion behind
# every app's `config/routes.rb`.
#
# `RouteTable` is defined here and reopened by the app, which supplies only
# `def self.table`. The verb helpers and the RESTful default actions
# (GET→index, POST→create, PUT→update, DELETE→destroy) are core-owned, so every
# app declares a row in the same form and the route-helper generator reads one
# grammar. `ActionDispatch::Router` owns matching only; `resources` expands a
# resource, and its two private helpers (`check_only`, `action_wanted`) sit
# beside it.
#
# Helpers construct `Route` rows without reading controller constants, so a row
# may name a class boot has not loaded. The table is built lazily on the first
# dispatch.

module Snails
  module RouteTable
    # a GET row, defaulting to the collection action.
    #
    # @param path [String] the path pattern, e.g. "/servers"
    # @param controller [Class] the controller class the row dispatches to
    # @param action [Symbol] the action, when it breaks the convention (e.g. :show)
    # @return [ActionDispatch::Router::Route] the constructed row
    # @example
    #   get("/servers", Api::ServersController)
    def self.get(path, controller, action = :index)
      ActionDispatch::Router::Route.new("GET", path, controller, action)
    end

    # a POST row, defaulting to the creation action.
    #
    # @param path [String] the path pattern, e.g. "/login"
    # @param controller [Class] the controller class the row dispatches to
    # @param action [Symbol] the action, when it breaks the convention
    # @return [ActionDispatch::Router::Route] the constructed row
    # @example
    #   post("/login", Api::LoginController)
    def self.post(path, controller, action = :create)
      ActionDispatch::Router::Route.new("POST", path, controller, action)
    end

    # a PUT row, defaulting to the update action.
    #
    # @param path [String] the path pattern, e.g. "/account/password"
    # @param controller [Class] the controller class the row dispatches to
    # @param action [Symbol] the action, when it breaks the convention
    # @return [ActionDispatch::Router::Route] the constructed row
    # @example
    #   put("/account/password", Api::PasswordsController)
    def self.put(path, controller, action = :update)
      ActionDispatch::Router::Route.new("PUT", path, controller, action)
    end

    # a DELETE row, defaulting to the destruction action.
    #
    # @param path [String] the path pattern, e.g. "/me/account"
    # @param controller [Class] the controller class the row dispatches to
    # @param action [Symbol] the action, when it breaks the convention
    # @return [ActionDispatch::Router::Route] the constructed row
    # @example
    #   delete("/me/account", Api::Me::AccountController)
    def self.delete(path, controller, action = :destroy)
      ActionDispatch::Router::Route.new("DELETE", path, controller, action)
    end

    # the five RESTful rows of a resource as `Array[Route]`: index/create on the
    # collection path, show/update/destroy on `path/:id`, collection rows before
    # member rows. The caller concatenates the result into its table;
    # first-match order is preserved exactly as declared.
    #
    # @param path [String] the collection path as written — a nested
    #   resource's parent segments are path text ("/posts/:post_id/
    #   comments"); member rows append "/:id"
    # @param controller [Class] the controller class every row
    #   dispatches to — `matched.controller.new`
    # @param format [Symbol, nil] the route-forced format on every row
    #   (nil = infer from path)
    # @param only [Array[Symbol], nil] the actions to keep, e.g.
    #   `[:create, :show]` — nil keeps all five. Rows come out in REST
    #   order regardless of the order named
    # @return [Array<ActionDispatch::Router::Route>] the selected rows
    # @raise [ArgumentError] `only` names something outside the five
    #   RESTful actions — a typo would otherwise silently drop the row
    # @example
    #   resources("/posts", Api::PostsController, :json)
    #   resources("/devices", Api::DevicesController, :json, [:create, :show])
    def self.resources(path, controller, format = nil, only = nil)
      check_only(only)
      rows = []
      rows << ActionDispatch::Router::Route.new("GET", path, controller, :index, format) if action_wanted(only, :index)
      rows << ActionDispatch::Router::Route.new("POST", path, controller, :create, format) if action_wanted(only, :create)
      rows << ActionDispatch::Router::Route.new("GET", path + "/:id", controller, :show, format) if action_wanted(only, :show)
      rows << ActionDispatch::Router::Route.new("PUT", path + "/:id", controller, :update, format) if action_wanted(only, :update)
      rows << ActionDispatch::Router::Route.new("DELETE", path + "/:id", controller, :destroy, format) if action_wanted(only, :destroy)
      rows
    end

    # every name in `only` must be one of the five RESTful actions. A typo there
    # would otherwise silently drop the row and the app would see a 404 where it
    # declared a route. Loud at table construction (boot), not at the first
    # request. A nil list has no names to check.
    #
    # @param only [Array[Symbol], nil] the action subset `resources` will keep
    # @raise [ArgumentError] `only` names an action outside the five RESTful ones
    def self.check_only(only)
      return if only.nil?
      i = 0
      while i < only.length
        name = only[i]
        if name != :index && name != :create && name != :show && name != :update && name != :destroy
          raise ArgumentError, "resources: unknown action #{name}"
        end
        i += 1
      end
    end

    # is `name` one of the caller's `only` list? A nil list selects everything;
    # membership is a `==` scan.
    #
    # @param only [Array[Symbol], nil] the action subset `resources` will keep
    # @param name [Symbol] the action the row would declare
    # @return [Boolean] true when the row survives the subset
    def self.action_wanted(only, name)
      return true if only.nil?
      j = 0
      while j < only.length
        return true if only[j] == name
        j += 1
      end
      false
    end

    # `check_only` / `action_wanted` back `resources` only — an app calls
    # `resources`, never these. Private on purpose: not supported for app
    # use, free to change or vanish without notice.
    private_class_method :check_only, :action_wanted
  end
end
