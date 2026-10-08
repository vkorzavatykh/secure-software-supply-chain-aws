import express, { type Express } from "express";
import helmet from "helmet";
import type { Logger } from "pino";
import { pinoHttp } from "pino-http";
import type { AppConfig } from "./config.js";
import { errorHandler, notFoundHandler } from "./errors.js";
import { healthRouter } from "./routes/health.js";
import { productsRouter } from "./routes/products.js";
import { versionRouter } from "./routes/version.js";

export interface AppDependencies {
  config: AppConfig;
  logger: Logger;
}

/** Builds the Express app without listening, so tests can drive it in-process. */
export function createApp({ config, logger }: AppDependencies): Express {
  const app = express();

  app.use(helmet());
  app.use(
    pinoHttp({
      logger,
      autoLogging: { ignore: (request) => request.url === "/health" },
      customLogLevel: (_request, response, error) => {
        if (error !== undefined || response.statusCode >= 500) return "error";
        if (response.statusCode >= 400) return "warn";
        return "info";
      },
    }),
  );

  app.use(healthRouter());
  app.use("/api", versionRouter(config), productsRouter());

  app.use(notFoundHandler);
  app.use(errorHandler);

  return app;
}
