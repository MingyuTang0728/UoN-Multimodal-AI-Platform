// Minimal backend: HTTP (Express) + WebSocket (ws) + optional Docker spawn
import express from 'express';
import http from 'http';
import { WebSocketServer } from 'ws';
import bodyParser from 'body-parser';
import { spawn } from 'child_process';

const PORT = process.env.PORT || 8080;
const app = express();
app.use(bodyParser.json({ limit: '10mb' }));

const server = http.createServer(app);
const wss = new WebSocketServer({ server });

/** WS simple pubsub (rooms by nodeId) **/
const clients = new Set();
wss.on('connection', (ws) => {
  ws.user = { apiKey: 'guest', rooms: new Set() };
  clients.add(ws);
  ws.on('message', (raw) => {
    try {
      const msg = JSON.parse(raw.toString());
      if (msg.type === 'hello') {
        ws.user.apiKey = msg.apiKey || 'guest';
      } else if (msg.type === 'join') {
        ws.user.rooms.add(msg.room);
      } else if (msg.type === 'chat') {
        // broadcast to room
        for (const c of clients) {
          if (c.readyState === 1 && c.user.rooms.has(msg.room)) {
            c.send(JSON.stringify({ ...msg, ts: Date.now() }));
          }
        }
      }
    } catch {}
  });
  ws.on('close', () => clients.delete(ws));
});

function broadcastEvalUpdate(payload) {
  // payload: { type:'evalUpdate', projectId, status, score }
  for (const c of clients) {
    try { c.send(JSON.stringify(payload)); } catch {}
  }
}

/** Eval start endpoint **/
app.post('/api/eval/start', async (req, res) => {
  const { projectId, nodeId, callbackUrl } = req.body || {};
  if (!projectId) return res.status(400).json({ error: 'projectId required' });

  // ---- Option A: simulate job (no Docker) ----
  const jobId = 'job_' + Math.random().toString(36).slice(2, 10);
  res.json({ jobId });

  // push queued -> running
  broadcastEvalUpdate({ type: 'evalUpdate', projectId, status: 'queued' });
  setTimeout(() => {
    broadcastEvalUpdate({ type: 'evalUpdate', projectId, status: 'running' });
  }, 500);

  // simulate compute and callback
  setTimeout(async () => {
    const score = +(Math.random() * 0.3 + 0.7).toFixed(3); // 0.7~1.0
    broadcastEvalUpdate({ type: 'evalUpdate', projectId, status: 'done', score });
    // If you prefer callback POST:
    // await fetch(callbackUrl, { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({ projectId, status:'done', score }) });
  }, 2500);

  // ---- Option B: real Docker (uncomment to use) ----
  // const image = process.env.EVAL_IMAGE || 'unicolab/evaluator:latest';
  // const args = ['run', '--rm', image, 'python', '/app/run_eval.py', projectId, callbackUrl];
  // const child = spawn('docker', args);
  // child.stdout.on('data', (d) => console.log('[eval]', d.toString()));
  // child.stderr.on('data', (d) => console.error('[eval]', d.toString()));
});

/** Optional: accept HTTP callback from container */
app.post('/api/callback', (req, res) => {
  const { projectId, status, score } = req.body || {};
  if (projectId) {
    broadcastEvalUpdate({ type: 'evalUpdate', projectId, status: status || 'done', score });
  }
  res.json({ ok: true });
});

server.listen(PORT, () => {
  console.log('UniCollab backend listening on http://localhost:' + PORT);
});