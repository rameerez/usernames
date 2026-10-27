// import "usernames" — in app/javascript/application.js, for the conventional
// importmap + Stimulus setup (stimulus-rails' controllers/application.js,
// which exports `application`). Registers the username-check controller on
// that application, once, after it exists: the import below orders it.
//
// An app that starts Stimulus some other way skips this file and registers
// the controller itself:
//
//   import UsernameCheckController from "usernames/username-check"
//   application.register("username-check", UsernameCheckController)
import { application } from "controllers/application"
import UsernameCheckController from "usernames/username-check"

application.register("username-check", UsernameCheckController)

export { UsernameCheckController }
