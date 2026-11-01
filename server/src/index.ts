// Worker entry point. Only the default export may live here: Workers treat every named export of the
// main module as an entrypoint, so the logic (and what tests import) lives in ./worker.
import { createHandler } from "./worker";

export default createHandler();
