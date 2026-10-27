# frozen_string_literal: true

require "test_helper"

class ProfilesController < ActionController::Base; end

# Usernames.route decides what ROUTES, not what may be registered: a name
# grandfathered in under older rules must still have a page.
class RouteTest < UsernamesTestCase
  ROUTABLE = %w[_javi -javi 3n oliver.__-hjj javi.json Javi_R a j.d.r 123].freeze

  def routes
    @routes ||= ActionDispatch::Routing::RouteSet.new.tap do |routes|
      routes.draw do
        get "@:username", to: "profiles#show", as: :profile, format: false, constraints: { username: Usernames.route }
        get ":username", to: "profiles#show", as: :bare_profile, format: false, constraints: { username: Usernames.route }
      end
    end
  end

  def recognize(path)
    routes.recognize_path(path)
  rescue ActionController::RoutingError
    nil
  end

  def test_the_route_pattern
    assert_equal(/[A-Za-z0-9._-]+/, Usernames.route)
    assert_same Usernames::ROUTE, Usernames.route
  end

  def test_has_no_anchors_so_rails_accepts_it_as_a_constraint
    refute_match(/\\A|\\z|\^|\$/, Usernames.route.source)
  end

  def test_at_style_profiles_route_every_name_including_ones_the_rules_refuse
    ROUTABLE.each do |name|
      assert_equal({ controller: "profiles", action: "show", username: name }, recognize("/@#{name}"), name)
    end
  end

  def test_bare_profiles_route_them_too
    ROUTABLE.each do |name|
      assert_equal name, recognize("/#{name}")&.fetch(:username), name
    end
  end

  # Without format: false Rails would read /@javi.json as username=javi, format=json.
  def test_a_dot_stays_in_the_username
    assert_equal "javi.json", recognize("/@javi.json")[:username]
    assert_nil recognize("/@javi.json")[:format]
  end

  def test_what_cannot_be_a_username_does_not_route
    assert_nil recognize("/@")
    assert_nil recognize("/@ja%20vi")
    assert_nil recognize("/@ja%40vi")
    assert_nil recognize("/@jos%C3%A9")
    assert_nil recognize("/@ja/vi")
  end

  def test_generates_paths
    assert_equal "/@oliver.__-hjj", routes.path_for(controller: "profiles", action: "show", username: "oliver.__-hjj")
  end
end
