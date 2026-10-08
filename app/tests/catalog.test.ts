import { describe, expect, it } from "vitest";
import { listProducts, products, type Product } from "../src/products/catalog.js";

const catalog: Product[] = [
  { id: "a", name: "A", category: "hardware", priceCents: 100, currency: "EUR" },
  { id: "b", name: "B", category: "software", priceCents: 200, currency: "EUR" },
  { id: "c", name: "C", category: "hardware", priceCents: 300, currency: "EUR" },
];

describe("listProducts", () => {
  it("returns every product when no category is given", () => {
    const page = listProducts({ limit: 10, offset: 0 }, catalog);

    expect(page.items.map((product) => product.id)).toEqual(["a", "b", "c"]);
    expect(page.total).toBe(3);
  });

  it("filters by category and counts only the matches", () => {
    const page = listProducts({ category: "hardware", limit: 10, offset: 0 }, catalog);

    expect(page.items.map((product) => product.id)).toEqual(["a", "c"]);
    expect(page.total).toBe(2);
  });

  it("pages through the matches, with total counting all of them", () => {
    const page = listProducts({ limit: 1, offset: 1 }, catalog);

    expect(page).toEqual({ items: [catalog[1]], total: 3, limit: 1, offset: 1 });
  });

  it("returns an empty page past the end", () => {
    const page = listProducts({ limit: 5, offset: 10 }, catalog);

    expect(page.items).toEqual([]);
    expect(page.total).toBe(3);
  });

  it("uses the built-in catalogue by default, which can't be modified", () => {
    expect(listProducts({ limit: 50, offset: 0 }).total).toBe(products.length);
    expect(Object.isFrozen(products)).toBe(true);
  });

  it("has unique product IDs in the built-in catalogue", () => {
    const ids = products.map((product) => product.id);

    expect(new Set(ids).size).toBe(ids.length);
  });
});
