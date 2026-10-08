import { Router } from "express";
import { z } from "zod";
import { HttpError } from "../errors.js";
import { categories, listProducts } from "../products/catalog.js";

export const maxPageSize = 50;

// Query values arrive as strings (or arrays, if a parameter is repeated); anything unexpected is a 400.
const listQuerySchema = z.object({
  category: z.enum(categories).optional(),
  limit: z.coerce.number().int().min(1).max(maxPageSize).default(20),
  offset: z.coerce.number().int().min(0).default(0),
});

export function productsRouter(): Router {
  const router = Router();

  router.get("/products", (request, response) => {
    const query = listQuerySchema.safeParse(request.query);
    if (!query.success) {
      throw new HttpError(400, "invalid_query", "Invalid query parameters", z.flattenError(query.error).fieldErrors);
    }

    response.json(listProducts(query.data));
  });

  return router;
}
