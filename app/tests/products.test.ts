import request from "supertest";
import { describe, expect, it } from "vitest";
import { products } from "../src/products/catalog.js";
import { maxPageSize } from "../src/routes/products.js";
import { createTestApp } from "./helpers.js";

interface ProductPageBody {
  items: { id: string; category: string }[];
  total: number;
  limit: number;
  offset: number;
}

interface ErrorBody {
  error: { code: string; message: string; details?: Record<string, string[]> };
}

describe("GET /api/products", () => {
  const app = createTestApp();

  it("returns the first page with default paging", async () => {
    const response = await request(app).get("/api/products");
    const body = response.body as ProductPageBody;

    expect(response.status).toBe(200);
    expect(body.limit).toBe(20);
    expect(body.offset).toBe(0);
    expect(body.total).toBe(products.length);
    expect(body.items).toHaveLength(Math.min(products.length, 20));
  });

  it("filters by category", async () => {
    const response = await request(app).get("/api/products").query({ category: "training" });
    const body = response.body as ProductPageBody;

    expect(response.status).toBe(200);
    expect(body.items.length).toBeGreaterThan(0);
    expect(body.items.every((product) => product.category === "training")).toBe(true);
    expect(body.total).toBe(products.filter((product) => product.category === "training").length);
  });

  it("parses limit and offset from the query string", async () => {
    const response = await request(app).get("/api/products").query({ limit: "2", offset: "1" });
    const body = response.body as ProductPageBody;

    expect(response.status).toBe(200);
    expect(body.items.map((product) => product.id)).toEqual(
      products.slice(1, 3).map((product) => product.id),
    );
    expect(body).toMatchObject({ limit: 2, offset: 1, total: products.length });
  });

  it("ignores unknown query parameters", async () => {
    const response = await request(app).get("/api/products").query({ sort: "price" });

    expect(response.status).toBe(200);
  });

  it.each([
    ["an unknown category", { category: "toys" }, "category"],
    ["a limit of zero", { limit: "0" }, "limit"],
    [`a limit above ${String(maxPageSize)}`, { limit: String(maxPageSize + 1) }, "limit"],
    ["a fractional limit", { limit: "1.5" }, "limit"],
    ["a negative offset", { offset: "-1" }, "offset"],
    ["a non-numeric offset", { offset: "first" }, "offset"],
  ])("rejects %s with a 400 that names the field", async (_case, query, field) => {
    const response = await request(app).get("/api/products").query(query);
    const body = response.body as ErrorBody;

    expect(response.status).toBe(400);
    expect(body.error.code).toBe("invalid_query");
    expect(body.error.details?.[field]).toBeDefined();
  });

  it("rejects a repeated parameter instead of picking one", async () => {
    const response = await request(app).get("/api/products?limit=1&limit=2");

    expect(response.status).toBe(400);
    expect((response.body as ErrorBody).error.details?.limit).toBeDefined();
  });
});
