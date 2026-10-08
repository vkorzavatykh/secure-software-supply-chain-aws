import { pino, type Logger } from "pino";
import type { LogLevel } from "./config.js";

/** Structured JSON logs on stdout. Credentials in request headers never reach the log. */
export function createLogger(level: LogLevel): Logger {
  return pino({
    level,
    base: { service: "sssc-demo-api" },
    timestamp: pino.stdTimeFunctions.isoTime,
    redact: {
      paths: ["req.headers.authorization", "req.headers.cookie", 'res.headers["set-cookie"]'],
      censor: "[redacted]",
    },
  });
}
