import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { loadConfig } from "../src/config.js";

const packageVersion = (
  JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")) as {
    version: string;
  }
).version;

describe("loadConfig", () => {
  it("uses safe defaults when nothing is set", () => {
    expect(loadConfig({})).toEqual({
      port: 3000,
      logLevel: "info",
      version: packageVersion,
      commit: "unknown",
    });
  });

  it("reads the port, log level and commit from the environment", () => {
    const config = loadConfig({ PORT: "8080", LOG_LEVEL: "warn", GIT_COMMIT: "abc1234" });

    expect(config).toMatchObject({ port: 8080, logLevel: "warn", commit: "abc1234" });
  });

  it.each([
    ["a non-numeric port", { PORT: "http" }, "PORT"],
    ["a port out of range", { PORT: "70000" }, "PORT"],
    ["an unknown log level", { LOG_LEVEL: "verbose" }, "LOG_LEVEL"],
    ["a blank commit", { GIT_COMMIT: "  " }, "GIT_COMMIT"],
  ])("refuses to start with %s", (_case, environment, variable) => {
    expect(() => loadConfig(environment)).toThrow(new RegExp(`Invalid configuration[\\s\\S]*${variable}`));
  });
});
