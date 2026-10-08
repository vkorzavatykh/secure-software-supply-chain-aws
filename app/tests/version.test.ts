import request from "supertest";
import { describe, expect, it } from "vitest";
import { createTestApp } from "./helpers.js";

describe("GET /api/version", () => {
  it("reports the package version and the build commit", async () => {
    const response = await request(createTestApp({ version: "2.0.0", commit: "f00dbab" })).get(
      "/api/version",
    );

    expect(response.status).toBe(200);
    expect(response.body).toEqual({ name: "sssc-demo-api", version: "2.0.0", commit: "f00dbab" });
  });
});
