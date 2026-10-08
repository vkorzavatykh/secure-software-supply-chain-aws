import type { ErrorRequestHandler, RequestHandler } from "express";

/** An error with a status code and a stable, machine-readable code, safe to show to clients. */
export class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly details?: unknown,
  ) {
    super(message);
    this.name = "HttpError";
  }
}

export const notFoundHandler: RequestHandler = (request, _response, next) => {
  next(new HttpError(404, "not_found", `No route for ${request.method} ${request.path}`));
};

/** Last middleware: known errors keep their status; anything else becomes a 500 without internals. */
export const errorHandler: ErrorRequestHandler = (error: unknown, request, response, _next) => {
  if (error instanceof HttpError) {
    response.status(error.status).json({
      error: { code: error.code, message: error.message, details: error.details },
    });
    return;
  }

  request.log.error({ err: error }, "unhandled error");
  response.status(500).json({
    error: { code: "internal_error", message: "Internal server error" },
  });
};
