import { Controller } from "@hotwired/stimulus"

// Live hints and an "is this name free?" check on a username field, from the
// usernames gem. `f.username_field :handle` puts it on the input itself;
// `f.username_status :handle` renders the <output> it writes to:
//
//   <input data-controller="username-check" data-action="input->username-check#check"
//          data-username-check-url-value="/usernames/availability"
//          data-username-check-target-value="user"
//          data-username-check-rules-value="[…User.handle_rules_for_browser…]"
//          data-username-check-status-id-value="user_handle_status"
//          aria-describedby="user_handle_status">
//   <output id="user_handle_status" for="user_handle" aria-live="polite"></output>
//
// The status gets a data-state for styling: checking, free, taken, invalid,
// unchanged (the record's saved name, so nothing to ask), error (the answer
// didn't come: offline, rate limited, switched off) or "" (nothing to say).
//
// Everything here is a HINT. The browser only approximates the server's
// normalisation (Ruby's strip and JavaScript's trim() disagree on NUL, U+FEFF
// and U+1680), so nothing here blocks submission: no setCustomValidity, no
// pattern attribute. The model's validations and the unique index decide.
export default class extends Controller {
  static values = {
    // GET <url>?username=<typed>&target=<target>; no url, no request (format hints only).
    url: String,
    target: String,
    rules: Array,
    lowercase: { type: Boolean, default: true },
    persisted: String,
    statusId: String,
    errorMessage: String,
    delay: { type: Number, default: 300 },
    // How long an answer may take, headers and body together, before it is an error.
    timeout: { type: Number, default: 8000 }
  }

  connect() {
    this.patterns = this.rulesValue.map((rule) => ({ ...rule, regexp: this.compile(rule.pattern) }))
    this.generation = 0
    this.reset = this.reset.bind(this)
    this.form = this.element.form
    if (this.form) this.form.addEventListener("reset", this.reset)
    document.addEventListener("turbo:before-cache", this.reset)
  }

  disconnect() {
    this.reset()
    if (this.form) this.form.removeEventListener("reset", this.reset)
    document.removeEventListener("turbo:before-cache", this.reset)
  }

  // On every keystroke: the saved name is simply unchanged; otherwise the
  // first rule the name breaks, at once, and whether it is free once
  // typing pauses. Every call starts a new generation: an answer for an
  // older one is never shown, even for the same name typed again (A, B, A).
  check() {
    const typed = this.element.value
    const generation = ++this.generation
    this.cancel()

    if (this.unchanged(typed)) return this.render({ state: "unchanged", message: "" })

    const name = this.normalize(typed)
    const broken = this.firstBrokenRule(name)
    if (broken) return this.render({ state: "invalid", message: broken.message })
    // Only names that could be registered are worth a request.
    if (name === "" || !this.urlValue) return this.render(null)

    this.render({ state: "checking", message: "" })
    this.timer = setTimeout(() => this.ask(name, generation), this.delayValue)
  }

  async ask(name, generation) {
    const request = new AbortController()
    this.request = request
    const url = new URL(this.urlValue, window.location.href)
    url.searchParams.set("username", name)
    if (this.targetValue) url.searchParams.set("target", this.targetValue)

    // The deadline covers the headers and the body alike: a stalled
    // connection, or a body that never finishes, ends in "error" too.
    // Aborting rejects `abandoned`, so neither await can outlive it.
    let timedOut = false
    const abandoned = new Promise((_resolve, reject) => {
      request.signal.addEventListener("abort", () => reject(new DOMException("Aborted", "AbortError")), { once: true })
    })
    abandoned.catch(() => {})
    const deadline = setTimeout(() => {
      timedOut = true
      request.abort()
    }, this.timeoutValue)
    this.deadline = deadline

    let answer = null
    try {
      const response = await Promise.race([fetch(url, {
        headers: { Accept: "application/json" },
        signal: request.signal,
        credentials: "same-origin"
      }), abandoned])
      if (response.ok) answer = await Promise.race([response.json(), abandoned])
    } catch (error) {
      // Cancelled because a newer check took over, or by a reset: say
      // nothing. Out of time is an answer of its own, below.
      if (error.name === "AbortError" && !timedOut) return
    } finally {
      clearTimeout(deadline)
    }
    // A slow answer for something typed earlier is not an answer for this.
    if (generation !== this.generation) return

    this.request = null
    // 429, 503, a network failure, no answer in time or something unreadable:
    // say so, never "checking" forever.
    this.render(this.understood(answer) ? answer : { state: "error", message: this.errorMessageValue })
  }

  // Forgets whatever is in flight and clears the status: on disconnect, when
  // the form is reset, and before Turbo caches the page.
  reset() {
    this.cancel()
    this.generation += 1
    this.render(null)
  }

  // The record's saved name, typed again (in any case, with or without a
  // leading @): the server would only say it is taken — by its owner.
  unchanged(typed) {
    return this.persistedValue !== "" && this.fold(typed) === this.fold(this.persistedValue)
  }

  // How the server compares two names, approximately: NFKC, trimmed, one
  // leading @ dropped, case ignored (in both case modes).
  fold(value) {
    return value.normalize("NFKC").trim().replace(/^@/, "").toLowerCase()
  }

  // The server's normalisation, approximately: NFKC, trim,
  // lowercase (unless case is kept), one leading @ before a letter or digit.
  normalize(value) {
    let name = value.normalize("NFKC").trim()
    if (this.lowercaseValue) name = name.toLowerCase().normalize("NFKC")
    return name.replace(this.lowercaseValue ? /^@(?=[a-z0-9])/ : /^@(?=[A-Za-z0-9])/, "")
  }

  // Each pattern matches a name that BREAKS its rule; the first one wins.
  firstBrokenRule(name) {
    if (name === "") return null
    return this.patterns.find(({ regexp }) => regexp && regexp.test(name)) || null
  }

  // With the u flag a length counts code points, as Ruby does.
  compile(pattern) {
    try {
      return new RegExp(pattern, "u")
    } catch {
      try { return new RegExp(pattern) } catch { return null }
    }
  }

  understood(answer) {
    return answer !== null && typeof answer === "object" && ["free", "taken", "invalid"].includes(answer.state) &&
      typeof answer.message === "string"
  }

  // The <output> named by the status-id value, or by the input's aria-describedby.
  get status() {
    const ids = [this.statusIdValue, ...(this.element.getAttribute("aria-describedby") || "").split(/\s+/)]
    for (const id of ids) {
      const element = id && document.getElementById(id)
      if (element && element.tagName === "OUTPUT") return element
    }
    return null
  }

  render(answer) {
    const status = this.status
    if (!status) return

    status.dataset.state = answer ? answer.state : ""
    status.textContent = answer && answer.message ? answer.message : ""
  }

  cancel() {
    clearTimeout(this.timer)
    clearTimeout(this.deadline)
    if (this.request) this.request.abort()
    this.request = null
  }
}
