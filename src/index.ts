import { EventEmitter } from "expo-modules-core";

import ExpoHttpServerModule from "./ExpoHttpServerModule";

type ExpoHttpServerEvents = {
  onRequest: (event: RequestEvent) => void | Promise<void>;
  onStatusUpdate: (event: StatusEvent) => void;
};

const emitter = new EventEmitter<ExpoHttpServerEvents>(ExpoHttpServerModule);
const requestCallbacks: Callback[] = [];

export type HttpMethod = "GET" | "POST" | "PUT" | "DELETE" | "OPTIONS";
/**
 * PAUSED AND RESUMED are iOS only
 */
export type Status = "STARTED" | "PAUSED" | "RESUMED" | "STOPPED" | "ERROR";

export interface StatusEvent {
  status: Status;
  message: string;
}

export interface RequestEvent {
  uuid: string;
  method: string;
  path: string;
  body: string;
  headersJson: string;
  paramsJson: string;
  cookiesJson: string;
}

export interface Response {
  statusCode?: number;
  statusDescription?: string;
  contentType?: string;
  headers?: Record<string, string>;
  body?: string;
}

export interface Callback {
  method: string;
  path: string;
  uuid: string;
  callback: (request: RequestEvent) => Promise<Response>;
}

export const start = () => {
  emitter.addListener("onRequest", async (event: RequestEvent) => {
    try {
      const responseHandler = requestCallbacks.find((c) => c.uuid === event.uuid);
      if (!responseHandler) {
        ExpoHttpServerModule.respond(
          event.uuid,
          404,
          "Not Found",
          "application/json",
          {},
          JSON.stringify({ error: "Handler not found" }),
        );
        return;
      }
      
      const response = await responseHandler.callback(event);
      
      // Validate response parameters
      const statusCode = response.statusCode || 200;
      if (statusCode < 100 || statusCode > 599) {
        console.warn(`ExpoHttpServer: Invalid status code ${statusCode}, using 500`);
        ExpoHttpServerModule.respond(
          event.uuid,
          500,
          "Internal Server Error",
          "application/json",
          {},
          JSON.stringify({ error: "Invalid status code" }),
        );
        return;
      }
      
      ExpoHttpServerModule.respond(
        event.uuid,
        statusCode,
        response.statusDescription || "OK",
        response.contentType || "application/json",
        response.headers || {},
        response.body || "{}",
      );
    } catch (error) {
      console.error("ExpoHttpServer: Error handling request:", error);
      ExpoHttpServerModule.respond(
        event.uuid,
        500,
        "Internal Server Error",
        "application/json",
        {},
        JSON.stringify({ error: "Internal server error" }),
      );
    }
  });
  ExpoHttpServerModule.start();
};

export const route = (
  path: string,
  method: HttpMethod,
  callback: (request: RequestEvent) => Promise<Response>,
) => {
  const uuid = Math.random().toString(16).slice(2);
  requestCallbacks.push({
    method,
    path,
    uuid,
    callback,
  });
  ExpoHttpServerModule.route(path, method, uuid);
};

export const setup = (
  port: number,
  onStatusUpdate?: (event: StatusEvent) => void,
) => {
  // Validate port number
  if (port <= 0 || port > 65535) {
    console.error(`ExpoHttpServer: Invalid port number ${port}. Port must be between 1 and 65535.`);
    if (onStatusUpdate) {
      onStatusUpdate({
        status: "ERROR",
        message: "Invalid port number. Port must be between 1 and 65535",
      });
    }
    return;
  }
  
  if (onStatusUpdate) {
    emitter.addListener("onStatusUpdate", (event: StatusEvent) => {
      onStatusUpdate(event);
    });
  }
  ExpoHttpServerModule.setup(port);
};

export const stop = () => ExpoHttpServerModule.stop();
