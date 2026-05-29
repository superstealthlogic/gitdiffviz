import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import process from "node:process";

function parseArgs(argv) {
  const options = {
    host: "127.0.0.1",
    port: 4173,
    scene: "examples/sample-scene.json"
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--host") options.host = argv[++index];
    else if (arg === "--port") options.port = Number(argv[++index]);
    else if (arg === "--scene") options.scene = argv[++index];
    else throw new Error(`Unknown argument: ${arg}`);
  }
  return options;
}

function contentType(filePath) {
  if (filePath.endsWith(".html")) return "text/html; charset=utf-8";
  if (filePath.endsWith(".css")) return "text/css; charset=utf-8";
  if (filePath.endsWith(".js") || filePath.endsWith(".mjs")) return "text/javascript; charset=utf-8";
  if (filePath.endsWith(".json")) return "application/json; charset=utf-8";
  return "text/plain; charset=utf-8";
}

const options = parseArgs(process.argv.slice(2));
const root = process.cwd();
const viewerRoot = path.join(root, "viewer");
const scenePath = path.resolve(root, options.scene);

const server = http.createServer((request, response) => {
  const url = new URL(request.url ?? "/", `http://${options.host}:${options.port}`);
  if (url.pathname === "/" || url.pathname === "/index.html") {
    const filePath = path.join(viewerRoot, "index.html");
    response.writeHead(200, { "Content-Type": contentType(filePath) });
    response.end(fs.readFileSync(filePath));
    return;
  }
  if (url.pathname === "/scene.json") {
    response.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
    response.end(fs.readFileSync(scenePath));
    return;
  }
  if (url.pathname.startsWith("/viewer/")) {
    const filePath = path.join(root, url.pathname.slice(1));
    if (!filePath.startsWith(viewerRoot) || !fs.existsSync(filePath)) {
      response.writeHead(404);
      response.end("Not found");
      return;
    }
    response.writeHead(200, { "Content-Type": contentType(filePath) });
    response.end(fs.readFileSync(filePath));
    return;
  }
  response.writeHead(404);
  response.end("Not found");
});

server.on("error", (error) => {
  console.error(`Failed to start viewer on ${options.host}:${options.port}: ${error.message}`);
  process.exitCode = 1;
});

server.listen(options.port, options.host, () => {
  console.log(`Git Visualization Diff viewer: http://${options.host}:${options.port}`);
  console.log(`Scene: ${scenePath}`);
});
