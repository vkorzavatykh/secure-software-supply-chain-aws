import { readFileSync } from "node:fs";
import { z } from "zod";

const logLevels = ["fatal", "error", "warn", "info", "debug", "trace", "silent"] as const;

export type LogLevel = (typeof logLevels)[number];

export interface AppConfig {
  port: number;
  logLevel: LogLevel;
  version: string;
  commit: string;
}

const environmentSchema = z.object({
  PORT: z.coerce.number().int().min(1).max(65_535).default(3000),
  LOG_LEVEL: z.enum(logLevels).default("info"),
  // Set at image build time (Dockerfile build argument); "unknown" in local runs.
  GIT_COMMIT: z.string().trim().min(1).default("unknown"),
});

function readPackageVersion(): string {
  const packageJson: unknown = JSON.parse(
    readFileSync(new URL("../package.json", import.meta.url), "utf8"),
  );
  return z.object({ version: z.string() }).parse(packageJson).version;
}

/** Reads and validates the configuration once, at startup. Invalid input stops the process. */
export function loadConfig(environment: NodeJS.ProcessEnv = process.env): AppConfig {
  const result = environmentSchema.safeParse(environment);
  if (!result.success) {
    throw new Error(`Invalid configuration:\n${z.prettifyError(result.error)}`);
  }

  return {
    port: result.data.PORT,
    logLevel: result.data.LOG_LEVEL,
    version: readPackageVersion(),
    commit: result.data.GIT_COMMIT,
  };
}
