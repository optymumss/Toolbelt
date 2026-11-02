// A tiny web server for the Chrome test's pages (node is already there for the test itself).
// Usage: node static-server.cjs <folder> <port>
const http = require("http");
const fs = require("fs");
const path = require("path");

const [root, port] = process.argv.slice(2);
const types = {
  ".html": "text/html", ".m3u8": "application/vnd.apple.mpegurl", ".ts": "video/mp2t", ".m4s": "video/iso.segment",
  ".mp4": "video/mp4", ".m4a": "audio/mp4", ".zip": "application/zip", ".pdf": "application/pdf",
  ".png": "image/png", ".key": "application/octet-stream", ".js": "text/javascript", ".css": "text/css",
};

http.createServer((request, response) => {
  let name = decodeURIComponent(new URL(request.url, "http://localhost").pathname);
  if (name.endsWith("/")) name += "index.html";
  const file = path.join(root, path.normalize(name));
  if (!file.startsWith(path.resolve(root))) {
    response.writeHead(403).end();
    return;
  }
  fs.stat(file, (error, stat) => {
    if (error || !stat.isFile()) {
      response.writeHead(404).end("Not found");
      return;
    }
    response.writeHead(200, { "Content-Type": types[path.extname(file).toLowerCase()] || "application/octet-stream",
                              "Content-Length": stat.size });
    fs.createReadStream(file).pipe(response);
  });
}).listen(Number(port), "127.0.0.1");
