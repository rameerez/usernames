# frozen_string_literal: true

require "json"

module Usernames
  # A username field with live hints and the availability check:
  #
  #   <%= form_with model: @user do |f| %>
  #     <%= f.label :handle %>
  #     <%= f.username_field :handle %>
  #     <%= f.username_status :handle %>
  #   <% end %>
  #
  # The field is a text field the `username-check` Stimulus controller
  # watches; the status is the live region it writes to. While someone
  # types, the field shows the first format rule the name breaks, then
  # whether it is free. Nothing blocks submission: the model decides.
  #
  #   f.username_field :handle, availability: false   # format hints only, no request
  #   f.username_field :handle, static: true          # a plain text field
  #
  # Every other option is the text field's, `class:` included.
  # `data: { controller:, action: }` and `aria: { describedby: }` are joined
  # with the field's own as token lists; the rest of `data:` and `aria:` is
  # merged in, and the field's own `username-check-*` values are the field's.
  #
  # The input's id is `field_id(:handle)` (`user_handle`), the status's
  # `field_id(:handle, :status)`. Two forms for the same record on one page
  # need different ones: pass `namespace:` to form_with, or the same `id:`
  # to both helpers.
  module FormBuilder
    def username_field(column = :username, availability: true, static: false, **html)
      column = column.to_sym
      html = Field.attributes(html)
      return text_field(column, Field::TYPING.merge(html)) if static

      own, input = username_field_ids(column, html)
      check = Field.check(@template, object, column, id: input, availability: availability)
      return text_field(column, Field::TYPING.merge(html)) if check.nil?

      text_field(column, Field.combine(Field::TYPING.merge(html), check).merge(id: own))
    end

    # <output id="user_handle_status" for="user_handle" aria-live="polite">,
    # empty until someone types; the controller sets its data-state
    # (checking, free, taken, invalid, unchanged, error) for styling.
    # Pass the field's `id:`, `namespace:` or `index:` here too if you gave it them.
    def username_status(column = :username, **html)
      html = Field.attributes(html)
      _own, input = username_field_ids(column, html)
      own = { id: "#{input}_status", for: input, aria: { "live" => "polite" } }
      @template.tag.output("", **Field.combine(html.except(:id, :namespace, :index), own))
    end

    private

    # The id the field gives Rails, and the id Rails renders from it. Given
    # explicitly, so the input has the id the status points at even where
    # form_with generates none; Rails prefixes the namespace to it (the
    # field's own `namespace:`, else the form's), so this does too, and a
    # field's own `index:` is in its id as in its name.
    def username_field_ids(column, html)
      own = html.fetch(:id) { field_id(column, namespace: nil, index: html.fetch(:index) { options[:index] }) }
      [own, username_input_id(own, html.fetch(:namespace) { options[:namespace] })]
    end

    # An input's id as Rails renders it: the namespace, then the id.
    def username_input_id(id, namespace)
      namespace ? "#{namespace}_#{id}" : id
    end
  end

  # The attributes behind the helpers. :nodoc:
  module Field
    # What tells a browser this is a username, not prose. Overridable:
    # `autocomplete: "nickname"` for a public handle that isn't a login.
    TYPING = { autocomplete: "username", autocapitalize: "none", autocorrect: "off", spellcheck: false }.freeze

    # Space-separated lists, where the caller's values join the field's own.
    TOKEN_LISTS = %w[data-controller data-action aria-describedby].freeze

    NESTED = %w[data aria].freeze

    MISSING_TARGET_LOGGED = Concurrent::AtomicBoolean.new(false)

    class << self
      # The data and aria attributes for a checked field, or nil when the
      # field can only be plain (a production form whose column is not a target).
      def check(template, object, column, id:, availability:)
        model = model_of!(object, column)
        endpoint = availability ? endpoint(template, model, column) : {}
        return if endpoint == :missing

        data = hints(object, model, column).merge("username-check-status-id-value" => "#{id}_status", **endpoint)
        { data: data.compact, aria: { "describedby" => "#{id}_status" } }
      end

      # The form's model, which must have declared has_username for `column`.
      def model_of!(object, column)
        model = object.class
        return model if model.respond_to?(:_usernames) && model._usernames.key?(column)

        raise ArgumentError, "username_field :#{column} needs a form for a model with has_username :#{column} " \
                             "(got #{object.inspect})"
      end

      # `data-…` and `aria-…` given as plain keys, moved into data: and
      # aria:, so there is one place to merge them.
      def attributes(html)
        html.each_with_object({}) do |(key, value), attributes|
          nested, name = key.to_s.split("-", 2)
          if value.is_a?(Hash)
            nested = key.to_s
            value = value.transform_keys { |each| each.to_s.dasherize }
          end
          next attributes[key.to_sym] = value unless NESTED.include?(nested)

          (attributes[nested.to_sym] ||= {}).merge!(name ? { name => value } : value)
        end
      end

      # The caller's attributes with the field's own over them: token lists
      # joined, data and aria merged (deeply), the field's values winning for
      # its own keys.
      def combine(theirs, ours)
        theirs.merge(ours) do |key, given, own|
          next own unless given.is_a?(Hash) && own.is_a?(Hash)

          given.deep_merge(own) { |name, mine, field| token_list?("#{key}-#{name}") ? tokens(mine, field) : field }
        end
      end

      private

      # What the browser needs for its format hints: the rules (in the model's
      # words), the case mode and the saved name. Every value a String, and
      # the rules encoded by the json gem itself, so rendering a field never
      # depends on Active Support's JSON encoder.
      def hints(object, model, column)
        {
          "controller" => "username-check",
          "action" => "input->username-check#check",
          "username-check-rules-value" => JSON.generate(model.public_send(:"#{column}_rules_for_browser")),
          "username-check-lowercase-value" => (model._usernames.fetch(column).mode != :preserve).to_s,
          "username-check-persisted-value" => persisted(object, column)
        }
      end

      # The endpoint's URL and this column's alias in config.availability.targets.
      def endpoint(template, model, column)
        url = url(template)
        return {} if url.nil?

        target = Targets.alias_for(model, column)
        return missing_target(model, column) if target.nil?

        { "username-check-url-value" => url, "username-check-target-value" => target,
          "username-check-error-message-value" => error_message }
      end

      # In the page's language, else in English, never "Translation missing"
      # (see Usernames::Locale).
      def error_message
        Locale.t(:usernames, :availability, :error)
      end

      # Through the app's route helper (`main_app` from inside an engine's
      # views), so a sub-URI deployment's SCRIPT_NAME is in it. None when
      # the app has no such route: the field then only hints.
      def url(template)
        routes = template.respond_to?(:main_app) ? template.main_app : template
        routes.usernames_availability_path if routes.respond_to?(:usernames_availability_path)
      end

      # Publishing a column takes a line in config.availability.targets: in
      # development and test, saying so loudly; in production, a plain
      # field and one log line rather than a broken page.
      def missing_target(model, column)
        target = "#{model.name}##{column}"
        why = "no entry in config.availability.targets names #{target}: add " \
              "{ #{model.name.to_s.underscore.tr('/', '_').inspect} => #{target.inspect} } to it, or pass " \
              "availability: false"
        raise ConfigurationError, "username_field :#{column} can't check availability: #{why}" if Rails.env.local?

        Rails.logger.error "[usernames] username_field :#{column} renders without its check: #{why}." if
          MISSING_TARGET_LOGGED.make_true
        :missing
      end

      def persisted(object, column)
        object.attribute_in_database(column).presence if object.respond_to?(:persisted?) && object.persisted?
      end

      def token_list?(name)
        TOKEN_LISTS.include?(name)
      end

      # Joined as Rails joins a token list (token_list, class_names): Arrays
      # flattened, a Hash keeping the keys whose values are truthy, nil and
      # false left out; then split on whitespace and deduplicated.
      def tokens(*lists)
        lists.flat_map { |list| token_values(list) }.flat_map { |value| value.to_s.split }.uniq.join(" ")
      end

      def token_values(value)
        case value
        when Hash then value.filter_map { |token, wanted| token if wanted }
        when Array then value.flat_map { |each| token_values(each) }
        when nil, false then []
        else [value]
        end
      end
    end
  end
end
