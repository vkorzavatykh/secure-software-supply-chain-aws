import type { Express } from "express";
import { createApp } from "../src/app.js";
import type { AppConfig } from "../src/config.js";
import { createLogger } from "../src/logger.js";

export const testConfig: AppConfig = {
  port: 0,
  logLevel: "silent",
  version: "1.2.3",
  commit: "abc1234",
};

export const silentLogger = createLogger("silent");

/** The real app, wired exactly as in production, with a fixed config and no log output. */
export function createTestApp(config: Partial<AppConfig> = {}): Express {
  return createApp({ config: { ...testConfig, ...config }, logger: silentLogger });
}
