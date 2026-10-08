import { Router } from "express";
import type { AppConfig } from "../config.js";

/** Which build is running: the package version and the commit the image was built from. */
export function versionRouter(config: Pick<AppConfig, "version" | "commit">): Router {
  const router = Router();
  const body = { name: "sssc-demo-api", version: config.version, commit: config.commit };

  router.get("/version", (_request, response) => {
    response.json(body);
  });

  return router;
}
