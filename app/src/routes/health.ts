import { Router } from "express";

/** Liveness: the process is up and serving requests. It has no dependencies to check. */
export function healthRouter(): Router {
  const router = Router();

  router.get("/health", (_request, response) => {
    response.json({ status: "ok" });
  });

  return router;
}
