# frozen_string_literal: true

module Usernames
  # The engine draws the availability route itself, after your routes, so
  # anything you declare wins. A catch-all such as `get "*path"` (or a
  # dynamic `get ":section/:page"`) would win too, and swallow it: declare
  # it yourself, above the catch-all, and the engine draws nothing.
  #
  #   Rails.application.routes.draw do
  #     usernames_availability
  #     get "*path", to: "pages#show"
  #   end
  #
  # Call it at the top level of the routes, outside any namespace or scope.
  # It answers at config.availability.path (or the path you pass), is named
  # `usernames_availability`, and takes no format: `/usernames/availability.json`
  # is not a route.
  module Routes
    DEFAULT_PATH = "/usernames/availability"

    def usernames_availability(path = nil)
      path ||= Usernames.configuration.availability.path || DEFAULT_PATH
      get path, to: "usernames/availability#show", as: :usernames_availability, format: false
    end
  end
end
