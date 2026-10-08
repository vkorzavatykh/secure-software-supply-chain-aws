export const categories = ["hardware", "software", "training"] as const;

export type Category = (typeof categories)[number];

export interface Product {
  id: string;
  name: string;
  category: Category;
  priceCents: number;
  currency: "EUR";
}

export interface ProductQuery {
  category?: Category | undefined;
  limit: number;
  offset: number;
}

export interface ProductPage {
  items: Product[];
  total: number;
  limit: number;
  offset: number;
}

/** A static, in-memory catalogue. The demo needs dependencies, not a database. */
export const products: readonly Product[] = Object.freeze([
  { id: "prd-001", name: "Hardware security key", category: "hardware", priceCents: 5_500, currency: "EUR" },
  { id: "prd-002", name: "Mechanical keyboard", category: "hardware", priceCents: 12_900, currency: "EUR" },
  { id: "prd-003", name: "USB-C docking station", category: "hardware", priceCents: 18_900, currency: "EUR" },
  { id: "prd-004", name: "Team password manager, 1 year", category: "software", priceCents: 4_800, currency: "EUR" },
  { id: "prd-005", name: "Code editor licence, 1 year", category: "software", priceCents: 9_900, currency: "EUR" },
  { id: "prd-006", name: "Static analysis seat, 1 year", category: "software", priceCents: 39_900, currency: "EUR" },
  { id: "prd-007", name: "Secure coding workshop", category: "training", priceCents: 49_000, currency: "EUR" },
  { id: "prd-008", name: "Cloud security fundamentals", category: "training", priceCents: 29_000, currency: "EUR" },
]);

/** Filters by category, then returns one page. total counts every match, not just the page. */
export function listProducts(
  query: ProductQuery,
  catalog: readonly Product[] = products,
): ProductPage {
  const matches =
    query.category === undefined
      ? catalog
      : catalog.filter((product) => product.category === query.category);

  return {
    items: matches.slice(query.offset, query.offset + query.limit),
    total: matches.length,
    limit: query.limit,
    offset: query.offset,
  };
}
