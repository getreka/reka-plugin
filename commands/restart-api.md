---
description: Rebuild and restart the local rag-api server
disable-model-invocation: true
---

Stop the running rag-api, rebuild, and restart:

1. `docker stop shared-rag-api 2>/dev/null || true`
2. `lsof -ti :3100 | xargs kill 2>/dev/null || true`
3. Find the rag-api directory (look for `rag-api/package.json` in the project or parent directories)
4. `cd <rag-api-dir> && npm run build`
5. `cd <rag-api-dir> && nohup node dist/server.js > /tmp/rag-api.log 2>&1 &`
6. Wait 2 seconds, then `curl -s http://localhost:3100/health` to confirm it's up
7. If health check fails, show last 20 lines of `/tmp/rag-api.log`
