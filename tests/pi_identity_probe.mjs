import extension from "../lib/hooks/am-state.ts";

const handlers = new Map();
extension({
  on(name, handler) {
    handlers.set(name, handler);
  },
});

const shouldRegister = process.env.EXPECT_PI_REGISTERED === "true";
const sessionStart = handlers.get("session_start");
if (!shouldRegister) {
  if (sessionStart) {
    throw new Error("pi extension registered for a non-pi session");
  }
  process.exit(0);
}
if (!sessionStart) {
  throw new Error("pi extension did not register for a pi session");
}

await sessionStart(
  {},
  {
    sessionManager: {
      getSessionId() {
        return process.env.TEST_PI_SESSION_ID;
      },
    },
  },
);
