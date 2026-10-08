import request from "supertest";
import { describe, expect, it } from "vitest";
import { createTestApp } from "./helpers.js";

describe("GET /health", () => {
  const app = createTestApp();

  it("reports that the service is up", async () => {
    const response = await request(app).get("/health");

    expect(response.status).toBe(200);
    expect(response.body).toEqual({ status: "ok" });
  });

  it("sends security headers and doesn't reveal the framework", async () => {
    const response = await request(app).get("/health");

    expect(response.headers["x-content-type-options"]).toBe("nosniff");
    expect(response.headers["content-security-policy"]).toContain("default-src 'self'");
    expect(response.headers["strict-transport-security"]).toBeDefined();
    expect(response.headers["x-powered-by"]).toBeUndefined();
  });
});
