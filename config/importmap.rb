# frozen_string_literal: true

# Drawn into the app's importmap by the engine (importmap-rails only).
# `import "usernames"` registers the username-check Stimulus controller on the
# app's own Stimulus application; "usernames/username-check" is the controller
# alone, for an app that registers it itself.
pin "usernames", to: "usernames/index.js"
pin "usernames/username-check", to: "usernames/username_check_controller.js"
