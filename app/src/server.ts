import { createApp } from "./app.js";
import { loadConfig } from "./config.js";
import { createLogger } from "./logger.js";

const config = loadConfig();
const logger = createLogger(config.logLevel);
const app = createApp({ config, logger });

const server = app.listen(config.port, (error?: Error) => {
  if (error) {
    logger.fatal({ err: error }, "failed to start");
    process.exit(1);
  }
  logger.info({ port: config.port, version: config.version, commit: config.commit }, "listening");
});

// Containers stop with SIGTERM: finish in-flight requests, then exit.
function shutdown(signal: NodeJS.Signals): void {
  logger.info({ signal }, "shutting down");
  server.close((error) => {
    if (error) {
      logger.error({ err: error }, "shutdown failed");
      process.exitCode = 1;
    }
  });
}

process.once("SIGTERM", shutdown);
process.once("SIGINT", shutdown);
