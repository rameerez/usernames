# frozen_string_literal: true

module Usernames
  # The username columns the availability endpoint answers for, by alias:
  # config.availability.targets, `{ "user" => "User#handle" }`.
  #
  # A request names an alias, and the alias is only ever a key looked up in
  # that Hash: the class name resolved is the one the app configured, never
  # anything a client sent. It is resolved on every lookup, so in
  # development a reloaded model is the new class, and a model that no
  # longer declares has_username fails loudly instead of answering for a
  # column that is gone. :nodoc:
  module Targets
    class << self
      # [model, column] for a configured alias; nil for anything else (the
      # endpoint's 404). Raises ConfigurationError when the alias is
      # configured but does not name a model with that has_username.
      def find(name)
        target = configured[name] if name.is_a?(String)
        resolve(name, target) if target
      end

      # The alias the form of a `model` record sends for `column`: the target
      # naming its class or, for a single-table subclass, the nearest parent
      # that one names. Compared by name; nothing is loaded.
      def alias_for(model, column)
        wanted = column.to_s
        model.ancestors.each do |ancestor|
          next unless ancestor.is_a?(Class) && ancestor.name

          found = configured.find { |_name, target| target == "#{ancestor.name}##{wanted}" }
          return found.first if found
        end
        nil
      end

      private

      def configured
        Usernames.configuration.availability.targets
      end

      def resolve(name, target)
        model_name, column = target.split("#", 2)
        model = constant(name, target, model_name)
        declared = model.is_a?(Class) && model.respond_to?(:_usernames) && model._usernames.key?(column.to_sym)
        unless declared && !model.abstract_class?
          broken!(name, target, "#{model_name} isn't a model that declares has_username :#{column}")
        end

        [model, column.to_sym]
      end

      def constant(name, target, model_name)
        Object.const_get(model_name)
      rescue NameError => e
        broken!(name, target, "#{model_name} can't be loaded (#{e.message})")
      end

      def broken!(name, target, why)
        raise ConfigurationError, "config.availability.targets[#{name.inspect}] is #{target.inspect}, but #{why}"
      end
    end
  end
end
