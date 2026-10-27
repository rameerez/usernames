# frozen_string_literal: true

require "test_helper"
require "open3"

# The shipped JavaScript, executed by node with Stimulus replaced by a bare
# class: every state the status can show, and every way an answer can go
# wrong. Skipped where node is not installed.
class JavascriptTest < UsernamesTestCase
  ROOT = File.expand_path("../../app/assets/javascripts/usernames", __dir__)
  CONTROLLER = File.join(ROOT, "username_check_controller.js")
  INDEX = File.join(ROOT, "index.js")

  # A Stimulus stand-in, a document with outputs and events, and a fetch the
  # scenario answers by hand. `scenario` is the body of an async function
  # whose `return` is printed as JSON.
  HARNESS = <<~JS
    class Controller {}
    globalThis.window = { location: { href: "https://app.test/signup" } }
    const outputs = {}
    globalThis.document = Object.assign(new EventTarget(), {
      getElementById: (id) => outputs[id] || null
    })
    const requests = []
    globalThis.fetch = (url, options) => new Promise((resolve, reject) => {
      const request = { url: new URL(url), options, resolve, reject }
      options.signal.addEventListener("abort", () => reject(Object.assign(new Error("aborted"), { name: "AbortError" })))
      requests.push(request)
    })
    const reply = (request, status, body) => request.resolve({
      ok: status >= 200 && status < 300, status,
      json: async () => (typeof body === "string" ? JSON.parse(body) : body)
    })
    const settle = (ms = 5) => new Promise((resolve) => setTimeout(resolve, ms))
    // A fetch that never answers and ignores its signal, as a stalled connection does.
    const stalled = () => new Promise(() => {})
    // Headers that arrive, then a body that never finishes.
    const stalledBody = () => Promise.resolve(new Response(new ReadableStream({
      start(stream) { stream.enqueue(new TextEncoder().encode('{"state":')) }
    }), { status: 200, headers: { "Content-Type": "application/json" } }))
    const output = (id, tagName = "OUTPUT") => (outputs[id] = { tagName, dataset: {}, textContent: "" })
    const rules = [
      { rule: "username_edges", pattern: "^[_]|[_]$", message: "can't start or end with an underscore" },
      { rule: "too_short", pattern: "^[\\\\s\\\\S]{0,2}$", message: "is too short" }
    ]
    function field({ value = "", persisted = "", url = "/usernames/availability", target = "user", lowercase = true,
                     statusId = "user_handle_status", describedby = "user_handle_status", timeout = 8000 } = {}) {
      const form = new EventTarget()
      const element = { value, form, getAttribute: (name) => (name === "aria-describedby" ? describedby : null) }
      const check = new UsernameCheck()
      Object.assign(check, { element, urlValue: url, targetValue: target, rulesValue: rules, lowercaseValue: lowercase,
                             persistedValue: persisted, statusIdValue: statusId,
                             errorMessageValue: "couldn't be checked just now", delayValue: 0,
                             timeoutValue: timeout })
      check.connect()
      const type = async (text) => { element.value = text; check.check(); await settle() }
      return { check, element, form, type }
    }
    const state = (id = "user_handle_status") => ({ state: outputs[id].dataset.state, text: outputs[id].textContent })
  JS

  def run_scenario(scenario)
    source = File.read(CONTROLLER)
      .sub(%r{^import \{ Controller \} from "@hotwired/stimulus"$}, "")
      .sub("export default class extends Controller", "const UsernameCheck = class extends Controller")
    script = "#{HARNESS}\n#{source}\nconsole.log(JSON.stringify(await (async () => {\n#{scenario}\n})()))"
    output, error, status = Open3.capture3(node, "--input-type=module", stdin_data: script)

    assert_predicate status, :success?, error
    JSON.parse(output)
  end

  # --- the files ------------------------------------------------------------------------------------------

  def test_both_files_are_valid_javascript_modules
    [CONTROLLER, INDEX].each do |file|
      _output, error, status = Open3.capture3(node, "--input-type=module", "--check", stdin_data: File.read(file))

      assert_predicate status, :success?, "#{file}: #{error}"
    end
  end

  def test_nothing_blocks_submission
    source = File.read(CONTROLLER)

    assert_includes source, "timeout: { type: Number, default: 8000 }", "an answer has eight seconds"

    refute_match(%r{^[^/]*setCustomValidity}, source)
    refute_match(%r{^[^/]*\.pattern\s*=}, source)
    refute_match(/preventDefault/, source)
  end

  # Pinned specifiers only: a relative import would not survive digesting.
  def test_imports_are_pinned_specifiers
    imports = [CONTROLLER, INDEX].flat_map { |file| File.read(file).scan(/^import .* from "([^"]+)"$/).flatten }

    assert_equal ["@hotwired/stimulus", "controllers/application", "usernames/username-check"], imports.sort
  end

  # The bridge registers the controller on the app's own Stimulus application, once.
  def test_the_index_registers_the_controller_once
    source = File.read(INDEX)
      .sub(%r{^import \{ application \} from "controllers/application"$},
           "const registered = []; const application = { register: (...args) => registered.push(args) }")
      .sub(%r{^import UsernameCheckController from "usernames/username-check"$}, "const UsernameCheckController = 'C'")
    output, error, status = Open3.capture3(node, "--input-type=module",
                                           stdin_data: "#{source}\nconsole.log(JSON.stringify(registered))")

    assert_predicate status, :success?, error
    assert_equal [%w[username-check C]], JSON.parse(output)
  end

  # --- the protocol ---------------------------------------------------------------------------------------

  def test_a_free_name
    result = run_scenario(<<~JS)
      output("user_handle_status")
      const { element, check } = field()
      element.value = "Ana"
      check.check()
      const checking = state()
      await settle()
      const asked = requests[0].url
      reply(requests[0], 200, { state: "free", message: "is available" })
      await settle()
      return { checking, asked: asked.pathname + asked.search, done: state() }
    JS

    assert_equal({ "state" => "checking", "text" => "" }, result["checking"])
    assert_equal "/usernames/availability?username=ana&target=user", result["asked"], "normalised, with the target"
    assert_equal({ "state" => "free", "text" => "is available" }, result["done"])
  end

  def test_taken_and_invalid_answers_are_shown_as_given
    result = run_scenario(<<~JS)
      output("user_handle_status")
      const { type } = field()
      const seen = []
      for (const answer of [{ state: "taken", message: "has already been taken" }, { state: "invalid", message: "is reserved" }]) {
        await type("javi" + seen.length)
        reply(requests.at(-1), 200, answer)
        await settle()
        seen.push(state())
      }
      return seen
    JS

    assert_equal [{ "state" => "taken", "text" => "has already been taken" },
                  { "state" => "invalid", "text" => "is reserved" }], result
  end

  def test_a_broken_rule_is_hinted_without_a_request
    result = run_scenario(<<~JS)
      output("user_handle_status")
      const { type } = field()
      await type("_javi")
      const edges = state()
      await type("ab")
      const short = state()
      await type("   ")
      return { edges, short, empty: state(), requests: requests.length }
    JS

    assert_equal({ "state" => "invalid", "text" => "can't start or end with an underscore" }, result["edges"])
    assert_equal({ "state" => "invalid", "text" => "is too short" }, result["short"])
    assert_equal({ "state" => "", "text" => "" }, result["empty"])
    assert_equal 0, result["requests"]
  end

  # A, then B, then A again: the first answer for A is stale, even though
  # it is for the same name as the last request.
  def test_a_b_a_shows_only_the_latest_answer
    result = run_scenario(<<~JS)
      output("user_handle_status")
      const { type } = field()
      await type("ana")
      const first = requests[0]
      await type("bob")
      await type("ana")
      const aborted = [first, requests[1]].map((request) => request.options.signal.aborted)
      reply(first, 200, { state: "taken", message: "stale A" })
      reply(requests[1], 200, { state: "taken", message: "stale B" })
      await settle()
      const meanwhile = state()
      reply(requests[2], 200, { state: "free", message: "is available" })
      await settle()
      return { aborted, meanwhile, done: state(), requests: requests.length }
    JS

    assert_equal [true, true], result["aborted"], "superseded requests are cancelled"
    assert_equal({ "state" => "checking", "text" => "" }, result["meanwhile"], "stale answers are never shown")
    assert_equal({ "state" => "free", "text" => "is available" }, result["done"])
    assert_equal 3, result["requests"]
  end

  # Whatever goes wrong, the status says so: it never stays "checking".
  def test_failures_end_in_error
    result = run_scenario(<<~JS)
      output("user_handle_status")
      const { type } = field()
      const outcomes = {}
      const cases = {
        429: (request) => reply(request, 429, ""),
        503: (request) => reply(request, 503, ""),
        404: (request) => reply(request, 404, ""),
        network: (request) => request.reject(new TypeError("Failed to fetch")),
        malformed: (request) => reply(request, 200, "<html>"),
        unknown: (request) => reply(request, 200, { state: "maybe", message: "?" }),
        nomessage: (request) => reply(request, 200, { state: "free" })
      }
      for (const [name, fail] of Object.entries(cases)) {
        await type("name_" + name)
        fail(requests.at(-1))
        await settle()
        outcomes[name] = state()
      }
      return outcomes
    JS

    result.each do |name, outcome|
      assert_equal({ "state" => "error", "text" => "couldn't be checked just now" }, outcome, name)
    end
  end

  # The deadline covers the headers and the body: a stalled connection, or a
  # body that never finishes, ends in "error" rather than "checking".
  def test_no_answer_in_time_is_an_error
    result = run_scenario(<<~JS)
      output("user_handle_status")
      const outcomes = {}
      for (const [name, stall] of Object.entries({ headers: stalled, body: stalledBody })) {
        const realFetch = globalThis.fetch
        let signal
        globalThis.fetch = (url, options) => { signal = options.signal; return stall() }
        const { type, check } = field({ timeout: 30 })
        await type("ana_" + name)
        const before = state().state
        await settle(80)
        outcomes[name] = { before, after: state(), aborted: signal.aborted }
        check.disconnect()
        globalThis.fetch = realFetch
      }
      return outcomes
    JS

    %w[headers body].each do |stall|
      error = { "state" => "error", "text" => "couldn't be checked just now" }

      assert_equal({ "before" => "checking", "after" => error, "aborted" => true }, result[stall], stall)
    end
  end

  # A request that a newer one replaced, or a reset cancelled, never comes
  # back as an error when its deadline would have passed.
  def test_a_cancelled_request_has_no_deadline
    result = run_scenario(<<~JS)
      output("user_handle_status")
      const superseded = field({ timeout: 30 })
      await superseded.type("ana")
      await superseded.type("bob")
      reply(requests.at(-1), 200, { state: "free", message: "is available" })
      await settle(80)
      const afterSupersede = state()
      superseded.check.disconnect()

      const reset = field({ timeout: 30 })
      await reset.type("carla")
      reset.form.dispatchEvent(new Event("reset"))
      await settle(80)
      return { afterSupersede, afterReset: state() }
    JS

    assert_equal({ "state" => "free", "text" => "is available" }, result["afterSupersede"])
    assert_equal({ "state" => "", "text" => "" }, result["afterReset"])
  end

  # An answer in time clears its deadline: nothing turns it into an error later.
  def test_an_answer_in_time_stays
    result = run_scenario(<<~JS)
      output("user_handle_status")
      const { type } = field({ timeout: 30 })
      await type("ana")
      reply(requests[0], 200, { state: "taken", message: "has already been taken" })
      await settle(80)
      return state()
    JS

    assert_equal({ "state" => "taken", "text" => "has already been taken" }, result)
  end

  # The record's saved name is unchanged — in any case, with a pasted @ —
  # and never asked about; that is the browser's call, not the server's.
  def test_the_saved_name_is_unchanged
    result = run_scenario(<<~JS)
      output("user_handle_status")
      const results = {}
      for (const lowercase of [true, false]) {
        const { type } = field({ persisted: "JaviR", lowercase })
        await type(" @javir ")
        results[lowercase ? "lowercase" : "preserve"] = state()
        await type("Javi_R")
        results[(lowercase ? "lowercase" : "preserve") + "_changed"] = state()
      }
      return { results, requests: requests.length }
    JS

    %w[lowercase preserve].each do |mode|
      assert_equal({ "state" => "unchanged", "text" => "" }, result["results"][mode], mode)
      assert_equal "checking", result["results"]["#{mode}_changed"]["state"], mode
    end
    assert_equal 2, result["requests"], "only the changed names were asked about"
  end

  # A grandfathered name the rules would refuse today is still just unchanged.
  def test_an_unchanged_grandfathered_name_is_not_hinted
    result = run_scenario(<<~JS)
      output("user_handle_status")
      const { type } = field({ persisted: "_old_" })
      await type("_old_")
      return state()
    JS

    assert_equal({ "state" => "unchanged", "text" => "" }, result)
  end

  def test_without_a_url_only_hints
    result = run_scenario(<<~JS)
      output("user_handle_status")
      const { type } = field({ url: "" })
      await type("_x")
      const hint = state()
      await type("ana")
      return { hint, valid: state(), requests: requests.length }
    JS

    assert_equal "invalid", result["hint"]["state"]
    assert_equal({ "state" => "", "text" => "" }, result["valid"])
    assert_equal 0, result["requests"]
  end

  def test_the_status_is_found_by_id_then_by_aria_describedby
    result = run_scenario(<<~JS)
      output("by_id")
      output("help", "P")
      output("by_described")
      const byId = field({ statusId: "by_id", describedby: "help by_described" })
      await byId.type("_x")
      const byDescribed = field({ statusId: "missing", describedby: "help by_described" })
      await byDescribed.type("_y")
      const none = field({ statusId: "", describedby: "" })
      await none.type("_z")
      return { byId: state("by_id"), byDescribed: state("by_described"), help: outputs.help.dataset.state ?? null }
    JS

    assert_equal "invalid", result["byId"]["state"]
    assert_equal "invalid", result["byDescribed"]["state"]
    assert_nil result["help"], "only an <output> is a status"
  end

  def test_reset_on_disconnect_form_reset_and_turbo_cache
    result = run_scenario(<<~JS)
      output("user_handle_status")
      const outcomes = {}
      const triggers = {
        disconnect: ({ check }) => check.disconnect(),
        reset: ({ form }) => form.dispatchEvent(new Event("reset")),
        turbo: () => document.dispatchEvent(new Event("turbo:before-cache"))
      }
      for (const [name, trigger] of Object.entries(triggers)) {
        const handle = field()
        await handle.type("ana_" + name)
        const request = requests.at(-1)
        trigger(handle)
        reply(request, 200, { state: "free", message: "late" })
        await settle()
        outcomes[name] = { ...state(), aborted: request.options.signal.aborted }
        handle.check.disconnect()
      }
      return outcomes
    JS

    result.each do |name, outcome|
      assert_equal({ "state" => "", "text" => "", "aborted" => true }, outcome, name)
    end
  end

  private

  def node
    found = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "node") }.find do |path|
      File.executable?(path)
    end
    found || skip("node is not installed")
  end
end
