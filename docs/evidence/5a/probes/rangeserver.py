import http.server, os, re, sys, time
FILE = "blob.bin"
SLOW = float(sys.argv[2]) if len(sys.argv) > 2 else 0.0   # seconds per 64 KB chunk
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_HEAD(self): self._serve(head=True)
    def do_GET(self): self._serve(head=False)
    def _serve(self, head):
        size = os.path.getsize(FILE); start, end = 0, size - 1
        rng = self.headers.get("Range")
        if rng:
            m = re.match(r"bytes=(\d+)-(\d*)", rng); start = int(m.group(1)); end = int(m.group(2) or size - 1)
            self.send_response(206); self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        else:
            self.send_response(200)
        self.send_header("Accept-Ranges", "bytes"); self.send_header("ETag", '"blob-v1"')
        self.send_header("Content-Length", str(end - start + 1)); self.end_headers()
        if head: return
        with open(FILE, "rb") as f:
            f.seek(start); left = end - start + 1
            while left > 0:
                chunk = f.read(min(65536, left)); left -= len(chunk)
                try: self.wfile.write(chunk)
                except BrokenPipeError: return
                if SLOW: time.sleep(SLOW)
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
