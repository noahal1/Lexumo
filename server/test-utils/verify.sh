#!/usr/bin/env bash
set -e
cd /c/Users/noaha/prj/lingueez-web/server
export DATA_DIR="$(mktemp -d)"
export PORT=8899
export HOST=127.0.0.1
node src/index.js > /tmp/lexumo-sync-server.log 2>&1 &
PID=$!
cleanup() { kill "$PID" 2>/dev/null || true; rm -rf "$DATA_DIR"; }
trap cleanup EXIT

for _ in $(seq 1 100); do
  if curl -sf http://127.0.0.1:8899/api/health >/dev/null 2>&1; then break; fi
  sleep 0.1
done

B=http://127.0.0.1:8899
J='content-type: application/json'

echo "== 1) GET /api/health =="
curl -s "$B/api/health"; echo

echo "== 2) POST /api/auth/register =="
REG=$(curl -s -X POST "$B/api/auth/register" -H "$J" -d '{"email":"Curl@Example.com","password":"password123"}')
echo "$REG"
TOKEN=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).token)' "$REG")

echo "== 3) POST /api/auth/login =="
curl -s -X POST "$B/api/auth/login" -H "$J" -d '{"email":"curl@example.com","password":"password123"}'; echo

echo "== 4) GET /api/me =="
curl -s "$B/api/me" -H "authorization: Bearer $TOKEN"; echo

echo "== 5) POST /api/sync 推 1 个词条 + 1 条日志 =="
PUSH=$(curl -s -X POST "$B/api/sync" -H "$J" -H "authorization: Bearer $TOKEN" -d '{"since":0,"changes":{"lists":[],"words":[{"id":"w1","term":"serendipity","definition":"意外发现美好事物的能力","definition2":"","example":"a serendipity moment","note":"","status":"new","favorite":false,"tags":["gre"],"listId":"l1","sourceLang":"en","targetLang":"zh-CN","listenCount":0,"srs":null,"createdAt":1700000000000,"updatedAt":1700000000000}],"logs":[{"id":"log1","wordId":"w1","grade":"good","at":1700000001000,"intervalBefore":1,"intervalAfter":2}],"settings":null}}')
echo "$PUSH"
REV=$(node -e 'process.stdout.write(String(JSON.parse(process.argv[1]).rev))' "$PUSH")

echo "== 6) POST /api/sync 增量拉取 since=$REV（应为空） =="
curl -s -X POST "$B/api/sync" -H "$J" -H "authorization: Bearer $TOKEN" -d "{\"since\":$REV,\"changes\":{}}"; echo

echo "== 7) POST /api/sync 再推第二个词条，since=$REV（只返回新增） =="
curl -s -X POST "$B/api/sync" -H "$J" -H "authorization: Bearer $TOKEN" -d '{"since":2,"changes":{"words":[{"id":"w2","term":"ephemeral","definition":"短暂的","definition2":"","example":"","note":"","status":"new","favorite":false,"tags":[],"listId":"l1","sourceLang":"en","targetLang":"zh-CN","listenCount":0,"srs":null,"createdAt":1700000002000,"updatedAt":1700000002000}],"logs":[],"lists":[],"settings":null}}'; echo

echo "== 8) 无令牌访问 /api/sync（应 401） =="
curl -s -o /dev/null -w 'HTTP %{http_code} ' "$B/api/sync" -X POST -H "$J" -d '{"since":0,"changes":{}}'
curl -s "$B/api/sync" -X POST -H "$J" -d '{"since":0,"changes":{}}'; echo

echo "== 9) CORS 预检 =="
curl -s -i -X OPTIONS "$B/api/sync" -H 'origin: http://localhost:1420' -H 'access-control-request-method: POST' | head -8

echo "== 10) 数据文件 =="
find "$DATA_DIR" -type f | sed "s|$DATA_DIR|DATA_DIR|"
echo "--- server log ---"
cat /tmp/lexumo-sync-server.log
