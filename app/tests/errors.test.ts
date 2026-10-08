import express from "express";
import { pinoHttp } from "pino-http";
import request from "supertest";
import { describe, expect, it } from "vitest";
import { errorHandler, HttpError, notFoundHandler } from "../src/errors.js";
import { createTestApp, silentLogger } from "./helpers.js";

/** A minimal app with routes that fail on purpose, behind the real error handling. */
function appThatFails() {
  const app = express();
  app.use(pinoHttp({ logger: silentLogger }));
  app.get("/http-error", () => {
    throw new HttpError(409, "conflict", "Already exists", { id: "prd-001" });
  });
  app.get("/crash", () => {
    throw new Error("connection to db.internal:5432 failed for user admin");
  });
  app.get("/async-crash", async () => {
    await Promise.resolve();
    throw new Error("secret detail");
  });
  app.use(notFoundHandler);
  app.use(errorHandler);
  return app;
}

describe("error handling", () => {
  it("answers unknown routes with a JSON 404", async () => {
    const response = await request(createTestApp()).get("/api/nothing-here");

    expect(response.status).toBe(404);
    expect(response.type).toBe("application/json");
    expect(response.body).toEqual({
      error: { code: "not_found", message: "No route for GET /api/nothing-here" },
    });
  });

  it("passes an HttpError's status, code and details to the client", async () => {
    const response = await request(appThatFails()).get("/http-error");

    expect(response.status).toBe(409);
    expect(response.body).toEqual({
      error: { code: "conflict", message: "Already exists", details: { id: "prd-001" } },
    });
  });

  it.each(["/crash", "/async-crash"])(
    "turns an unexpected error in %s into a 500 without internal details",
    async (path) => {
      const response = await request(appThatFails()).get(path);

      expect(response.status).toBe(500);
      expect(response.body).toEqual({
        error: { code: "internal_error", message: "Internal server error" },
      });
      expect(response.text).not.toMatch(/db\.internal|admin|secret|stack/i);
    },
  );
});
