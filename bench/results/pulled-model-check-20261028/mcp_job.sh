#!/bin/bash
# Real harness job via the MCP endpoint (strim_task), then poll strim_job. Cap 10 min. Output in $W/mcp_*.txt
PORT=${PORT:-8203}; TOK=$(cat ~/.strim/token); W=/tmp/strim-live-work; U=http://127.0.0.1:$PORT/mcp
H=(-H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream')
curl -s -D $W/mcp_h.txt -m 30 $U "${H[@]}" -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"live-shots","version":"1"}}}' > $W/mcp_init.txt
SID=$(grep -i '^mcp-session-id' $W/mcp_h.txt | awk '{print $2}' | tr -d '\r'); [ -n "$SID" ] && H+=(-H "Mcp-Session-Id: $SID")
curl -s -m 30 $U "${H[@]}" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' > /dev/null
TASK='Fix the failing test in this Go module: TestMean fails. Make the smallest change to the non-test source so `go test ./...` passes. Do not edit tests.'
jq -n --arg t "$TASK" --arg cwd "$HOME/strim-live-demo" '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:"strim_task",arguments:{task:$t,cwd:$cwd,access:"write",verify:"go test ./...",wait_s:25}}}' \
  | curl -s -m 60 $U "${H[@]}" -d @- > $W/mcp_task.txt
cat $W/mcp_task.txt
