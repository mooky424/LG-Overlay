"use strict";

const http = require("http");
const net = require("net");
const { URL } = require("url");

const listenHost = process.env.PROXY_HOST || "127.0.0.1";
const listenPort = Number(process.env.PROXY_PORT || 4201);
const frontendTarget = new URL(process.env.FRONTEND_TARGET || "http://127.0.0.1:4200");
const apiTarget = new URL(process.env.API_TARGET || "http://127.0.0.1:5101");
const socketTarget = new URL(process.env.SOCKET_TARGET || "http://127.0.0.1:5200");

function isSocketPath(requestUrl) {
  const pathname = new URL(requestUrl || "/", "http://proxy.invalid").pathname;
  return pathname === "/socket.io" || pathname.startsWith("/socket.io/");
}

function getTargetPath(requestUrl, prefix) {
  const request = new URL(requestUrl || "/", "http://proxy.invalid");
  let pathname = request.pathname;

  if (prefix && (pathname === prefix || pathname.startsWith(`${prefix}/`))) {
    pathname = pathname.slice(prefix.length) || "/";
  }

  return `${pathname}${request.search}`;
}

function proxyError(response, error) {
  console.error(`Proxy error: ${error.message}`);
  if (response.destroyed || response.headersSent) {
    return;
  }

  response.writeHead(502, { "content-type": "text/plain; charset=utf-8" });
  response.end("Bad gateway");
}

function forwardRequest(request, response, target, prefix, onResponse) {
  const headers = { ...request.headers, host: target.host };
  const upstream = http.request(
    {
      hostname: target.hostname,
      port: target.port || 80,
      method: request.method,
      path: getTargetPath(request.url, prefix),
      headers,
    },
    onResponse,
  );

  upstream.on("error", (error) => proxyError(response, error));
  request.on("aborted", () => upstream.destroy());
  request.pipe(upstream);
}

function proxyConfig(request, response) {
  forwardRequest(request, response, frontendTarget, undefined, (upstreamResponse) => {
    const chunks = [];

    upstreamResponse.on("data", (chunk) => chunks.push(chunk));
    upstreamResponse.on("end", () => {
      const originalBody = Buffer.concat(chunks);
      let body = originalBody;
      let rewritten = false;

      try {
        if (upstreamResponse.statusCode >= 200 && upstreamResponse.statusCode < 300) {
          const config = JSON.parse(originalBody.toString("utf8"));
          config.serverEndpoint = "/";
          config.extrasEndpoint = "/api";
          body = Buffer.from(JSON.stringify(config, null, 2));
          rewritten = true;
        }
      } catch (error) {
        console.error(`Could not rewrite frontend config: ${error.message}`);
      }

      const headers = { ...upstreamResponse.headers };
      if (rewritten) {
        delete headers.etag;
        delete headers["last-modified"];
        delete headers["content-encoding"];
        delete headers["transfer-encoding"];
        headers["content-type"] = "application/json; charset=utf-8";
      }
      headers["content-length"] = body.length;
      delete headers["transfer-encoding"];

      response.writeHead(upstreamResponse.statusCode || 502, headers);
      response.end(body);
    });
  });
}

const server = http.createServer((request, response) => {
  const pathname = new URL(request.url || "/", "http://proxy.invalid").pathname;

  if (pathname === "/assets/config/config.json") {
    proxyConfig(request, response);
  } else if (pathname === "/api" || pathname.startsWith("/api/")) {
    forwardRequest(request, response, apiTarget, "/api", (upstreamResponse) => {
      response.writeHead(upstreamResponse.statusCode || 502, upstreamResponse.headers);
      upstreamResponse.pipe(response);
    });
  } else if (isSocketPath(request.url)) {
    forwardRequest(request, response, socketTarget, undefined, (upstreamResponse) => {
      response.writeHead(upstreamResponse.statusCode || 502, upstreamResponse.headers);
      upstreamResponse.pipe(response);
    });
  } else {
    forwardRequest(request, response, frontendTarget, undefined, (upstreamResponse) => {
      response.writeHead(upstreamResponse.statusCode || 502, upstreamResponse.headers);
      upstreamResponse.pipe(response);
    });
  }
});

server.on("upgrade", (request, clientSocket, head) => {
  if (!isSocketPath(request.url)) {
    clientSocket.destroy();
    return;
  }

  const upstreamSocket = net.connect(
    Number(socketTarget.port || 80),
    socketTarget.hostname,
    () => {
      const headers = { ...request.headers, host: socketTarget.host };
      let requestHeader = `${request.method} ${getTargetPath(request.url)} HTTP/${request.httpVersion}\r\n`;

      for (const [name, value] of Object.entries(headers)) {
        if (Array.isArray(value)) {
          requestHeader += `${name}: ${value.join(", ")}\r\n`;
        } else if (value !== undefined) {
          requestHeader += `${name}: ${value}\r\n`;
        }
      }

      upstreamSocket.write(`${requestHeader}\r\n`);
      if (head.length > 0) {
        upstreamSocket.write(head);
      }

      clientSocket.pipe(upstreamSocket);
      upstreamSocket.pipe(clientSocket);
    },
  );

  upstreamSocket.on("error", () => clientSocket.destroy());
  clientSocket.on("error", () => upstreamSocket.destroy());
});

server.listen(listenPort, listenHost, () => {
  console.log(
    `Spectra reverse proxy running on http://${listenHost}:${listenPort} (frontend ${frontendTarget}, api ${apiTarget}, socket ${socketTarget})`,
  );
});
